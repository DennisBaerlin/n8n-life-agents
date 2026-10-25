-- ============================================================
-- V027 (finance) — Versicherung: Beitrag/Rhythmus/Tag/Vertragsende/Konto nur noch an der Raten-Kette.
--
--   WARUM (WP2 "Finanzen schlank"): insurances.annual_premium/monthly_equivalent/schedule_*/valid_to/account_id
--   doppelten die Beitrags-rp. active_insurances las die Kopien, der Cashflow die rp -> zwei Wahrheiten; ausserdem
--   rechnete das Sprachmodell "30 EUR monatlich" in einen Jahresbeitrag um. Neu: die rp traegt den Betrag JE ABBUCHUNG
--   (die Wahrheit), active_insurances leitet Jahres-/Monatswert ab (fn_annual_equivalent, rp.monthly_equivalent).
--
--   (1) PRE-FLIGHT (fail-loud mit ids): gleicher Rhythmus, Betrag je Abbuchung = fn_insurance_period_amount(Jahres-
--       praemie) bis auf 0,01 (aeltere Tool-Staende rechneten in n8n und konnten um einen Cent abweichen -- dann gilt
--       die gebuchte rp). Ein groesserer Unterschied bricht ab; nichts wird still geaendert.
--   (2) Vertragsende nur an der Police (rp ohne Ende) -> in die rp uebernehmen (Fakt bleibt erhalten); sonst gilt die rp.
--   (3) Police OHNE Raten-rp: kein Abbruch -- der Jahresbeitrag wandert in notes (die Police bleibt als beitragsfrei
--       im Register; einen Cashflow hatte sie ohne rp nie).
--   (4) active_insurances CASCADE droppen (R__finance_views legt sie neu an), GENERATED-Spalte zuerst, dann die Kopien.
--   fn_insurance_period_amount liegt im Init (V laeuft vor allen R__-fns). FRISCHE DB: Alt-Spalten nie vorhanden ->
--   Spalten-Guard + EXECUTE, DROP COLUMN IF EXISTS (schedule_day_of_month war nur Geruest fuer V012/V024). Re-run-sicher.
-- ============================================================

DO $$
DECLARE
    v_bad TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'finance' AND table_name = 'insurances' AND column_name = 'annual_premium') THEN
        -- (1) Pre-flight
        EXECUTE $q$
            SELECT string_agg(i.id::text || ' (' || x.why || ')', ', ' ORDER BY i.id)
            FROM finance.insurances i
            JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
            CROSS JOIN LATERAL (SELECT CASE
                WHEN rp.schedule_interval IS DISTINCT FROM i.schedule_interval
                  OR rp.schedule_unit IS DISTINCT FROM i.schedule_unit
                    THEN 'Rhythmus ' || i.schedule_interval || ' ' || i.schedule_unit
                         || ' vs. Raten-Zeile ' || rp.schedule_interval || ' ' || rp.schedule_unit
                WHEN abs(abs(rp.amount) - finance.fn_insurance_period_amount(i.annual_premium, i.schedule_interval, i.schedule_unit)) > 0.01
                    THEN 'Beitrag je Abbuchung ' || finance.fn_insurance_period_amount(i.annual_premium, i.schedule_interval, i.schedule_unit)
                         || ' vs. Raten-Zeile ' || abs(rp.amount)
                END AS why) x
            WHERE x.why IS NOT NULL
        $q$ INTO v_bad;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'V027 pre-flight: Versicherung und Beitrags-Zeile weichen ab bei Versicherungs-id %. Beitrag/Rhythmus '
                'per set_insurance angleichen, dann erneut migrieren.', v_bad;
        END IF;

        -- (2) Vertragsende nur an der Police -> rp
        EXECUTE $q$
            UPDATE finance.recurring_payments rp
               SET valid_to = i.valid_to
              FROM finance.insurances i
             WHERE i.recurring_payment_id = rp.id AND i.valid_to IS NOT NULL AND rp.valid_to IS NULL
        $q$;

        -- (3) Police ohne rp -> Jahresbeitrag in die Notiz
        EXECUTE $q$
            UPDATE finance.insurances
               SET notes = concat_ws(E'\n', notes,
                               'Jahresbeitrag laut Erfassung: ' || to_char(annual_premium, 'FM999999990.00') || ' (ohne Beitrags-Zeile)')
             WHERE recurring_payment_id IS NULL AND annual_premium IS NOT NULL
        $q$;
    END IF;
END $$;

-- (4)
DROP VIEW IF EXISTS finance.active_insurances CASCADE;
ALTER TABLE finance.insurances DROP COLUMN IF EXISTS monthly_equivalent;
ALTER TABLE finance.insurances
    DROP COLUMN IF EXISTS annual_premium,
    DROP COLUMN IF EXISTS schedule_interval,
    DROP COLUMN IF EXISTS schedule_unit,
    DROP COLUMN IF EXISTS schedule_day_of_month,
    DROP COLUMN IF EXISTS valid_to,
    DROP COLUMN IF EXISTS account_id;
