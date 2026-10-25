-- ============================================================
-- V026 (finance) — Kredit: Rate/Rhythmus/Abbuchungstag nur noch an der Raten-Kette; "anfaengliche Tilgung" ableiten.
--
--   WARUM (WP2 "Finanzen schlank", Live-Befund 2026-10-25): loans.monthly_annuity doppelte recurring_payments.amount,
--   loans.schedule_interval/_unit/_day_of_month den Rhythmus der Raten-rp (niemand las sie), und die gespeicherte
--   "anfaengliche Tilgung" principal_rate widersprach der echten Rate. Regel .claude/rules/sql.md "Keine ableitbaren
--   Spalten": die Raten-Kette ist die eine Quelle (loan_overview liest das heute gueltige Glied), die anfaengliche
--   Tilgung rechnet loan_overview.initial_principal_rate.
--
--   (1) PRE-FLIGHT (fail-loud mit ids): Kopie und Raten-rp muessen dieselbe Rate tragen -- sonst zeigte die Uebersicht
--       heute schon etwas anderes als gebucht wird; nichts wird still geaendert. Die nie gelesenen Kopien von Rhythmus
--       und Tag pruefen wir nicht (die rp trieb immer Erinnerung und Buchung).
--   (2) Rate OHNE Raten-rp (Altbestand: fn_set_loan setzte eine Rate an einem Kredit ohne rp): kein Abbruch -- der
--       Betrag wandert in notes, ein aktiver Kredit wird pausiert (ohne Raten-Kette gibt es keine faellige Rate).
--   (3) CHECK-Tausch: aktiv <=> Raten-Kette vorhanden (vorher: aktiv <=> monthly_annuity). Das Init legt den neuen CHECK
--       erst an, wenn monthly_annuity weg ist (Init laeuft vor dieser V; Reviewer-Blocker 3).
--   (4) loan_overview CASCADE droppen (R__finance_views legt alle Views danach neu an), Spalten droppen.
--   FRISCHE DB: die Alt-Spalten gab es nie (das Init traegt den Endzustand; schedule_day_of_month nur als Geruest fuer
--   V012/V024) -> Pre-flight/Backfill uebersprungen (Spalten-Guard + EXECUTE, PL/pgSQL plant sonst beim ersten Lauf),
--   DROP COLUMN IF EXISTS. Re-run-sicher.
-- ============================================================

DO $$
DECLARE
    v_bad TEXT;
BEGIN
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_schema = 'finance' AND table_name = 'loans' AND column_name = 'monthly_annuity') THEN
        -- (1) Pre-flight
        EXECUTE $q$
            SELECT string_agg(l.id::text || ' (Rate ' || l.monthly_annuity || ', Raten-Zeile ' || (-rp.amount) || ')', ', '
                              ORDER BY l.id)
            FROM finance.loans l
            JOIN finance.recurring_payments rp ON rp.id = l.recurring_payment_id
            WHERE l.monthly_annuity IS NOT NULL AND rp.amount <> -l.monthly_annuity
        $q$ INTO v_bad;
        IF v_bad IS NOT NULL THEN
            RAISE EXCEPTION 'V026 pre-flight: Kreditrate und Raten-Zeile weichen ab bei Kredit-id %. Rate am Kredit '
                'per set_loan auf den abgebuchten Betrag setzen (oder die Raten-Zeile korrigieren), dann erneut migrieren.', v_bad;
        END IF;

        -- (2) Rate ohne Raten-Kette -> Notiz + pausiert
        EXECUTE $q$
            UPDATE finance.loans
               SET notes  = concat_ws(E'\n', notes,
                                'Rate laut Erfassung: ' || to_char(monthly_annuity, 'FM999999990.00') || ' (ohne Raten-Zeile)'),
                   status = CASE WHEN status = 'active' THEN 'paused'::finance.loan_status ELSE status END
             WHERE recurring_payment_id IS NULL AND monthly_annuity IS NOT NULL
        $q$;
    END IF;
END $$;

-- (3) + (4): CHECK-Tausch als DROP+ADD im DO-Block (Muster V012/V024: derselbe Name, neue Bedingung; die Garantie
-- "aktiv hat eine Rate" bleibt, nur ihre Adresse wechselt auf die Raten-Kette).
DROP VIEW IF EXISTS finance.loan_overview CASCADE;
DO $$ BEGIN
    ALTER TABLE finance.loans DROP CONSTRAINT IF EXISTS finance_loans_active_needs_annuity;
    ALTER TABLE finance.loans
        DROP COLUMN IF EXISTS principal_rate,
        DROP COLUMN IF EXISTS monthly_annuity,
        DROP COLUMN IF EXISTS schedule_interval,
        DROP COLUMN IF EXISTS schedule_unit,
        DROP COLUMN IF EXISTS schedule_day_of_month;
    ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_active_needs_annuity
        CHECK (recurring_payment_id IS NOT NULL OR status <> 'active');
END $$;
