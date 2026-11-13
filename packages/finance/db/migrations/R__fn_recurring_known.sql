-- ============================================================
-- fn_recurring_known (READ, STABLE) -- ist eine erkannte Reihe schon ein Dauerauftrag? Die eine Adresse des Bekannt-Filters
--   fuer Bank-Export (fn_get_recurring_candidates mode export) und Kontoauszug (mode statement) sowie fuer den Knopf-Tipp.
--   Kandidaten = jede laufende Zeile (Praedikat von finance.active_recurring_payments) oder eine erst kuenftig startende
--   (sonst kaeme ein eben angelegter Vorschlag gleich wieder), auch Versicherung/Kredit/Sparziel/Vorsorge.
--   Auf diesem Konto (Quelle oder Ziel, gleiches Vorzeichen):
--   (a) IBAN-Schluessel der Kette + Betrag 50-150 % (geteilte IBAN eines Zahlungsdienstes: +-7,5 %),
--   (b) Transfer mit demselben Gegenkonto + Betrag 50-150 %,
--   (c) exakter Betrag im gleichen Rhythmus am gleichen Tag (+-tol, Kreis-Kalender) ohne fremden IBAN-Schluessel,
--   (d) Namens-Wort (>= 4 Zeichen, Trennzeichen wie fn_statement_match Stufe B) im Namen + Betrag +-7,5 %,
--   (e) Mandat (Glaeubiger-ID|Mandatsreferenz) als sepa_mandate-Schluessel einer Kette (global eindeutig, jedes Konto).
--   Bewusst nicht fn_name_matches: der vergleicht ganze Namen ("NETFLIX INTERNATIONAL B.V." gegen "Netflix").
--   (a)/(d) auf einem anderen Konto -> elsewhere = dessen Kontoname.
--   Eingabe p: {account_id*, sign* (1|-1), amount* (positiv), iban, shared (bool), other_account_id, unit, interval, dom,
--   tol (def 3), name, mandate}. Rueckgabe: {known:bool, elsewhere?:text}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_known(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_acct   INT     := (p->>'account_id')::int;
    v_sign   INT     := (p->>'sign')::int;
    v_amt    NUMERIC := abs((p->>'amount')::numeric);
    v_iban   TEXT    := NULLIF(p->>'iban', '');
    v_shared BOOLEAN := COALESCE((p->>'shared')::boolean, false);
    v_other  INT     := NULLIF(p->>'other_account_id', '')::int;
    v_unit   TEXT    := NULLIF(p->>'unit', '');
    v_int    INT     := NULLIF(p->>'interval', '')::int;
    v_dom    INT     := NULLIF(p->>'dom', '')::int;
    v_tol    INT     := COALESCE(NULLIF(p->>'tol', '')::int, 3);
    v_txt    TEXT    := lower(COALESCE(p->>'name', ''));
    v_mand   TEXT    := NULLIF(p->>'mandate', '');
    v_else   TEXT;
BEGIN
    IF v_mand IS NOT NULL AND EXISTS (
        SELECT 1 FROM finance.recurring_payment_keys k
        JOIN finance.recurring_payments r ON r.id = k.recurring_payment_id
        WHERE k.key_type = 'sepa_mandate' AND k.key_value = v_mand
          AND (r.id IN (SELECT ar.id FROM finance.active_recurring_payments ar)
               OR (r.status = 'active' AND r.valid_from > current_date))) THEN
        RETURN jsonb_build_object('known', true);
    END IF;

    IF EXISTS (
        SELECT 1 FROM finance.recurring_payments r
        CROSS JOIN LATERAL (SELECT CASE WHEN r.account_id = v_acct THEN r.amount ELSE abs(r.amount) END AS e,
                                   CASE WHEN r.account_id = v_acct THEN r.target_account_id ELSE r.account_id END AS o) x
        WHERE (r.id IN (SELECT ar.id FROM finance.active_recurring_payments ar)
               OR (r.status = 'active' AND r.valid_from > current_date))
          AND (r.account_id = v_acct OR r.target_account_id = v_acct)
          AND sign(x.e) = v_sign
          AND ( (v_iban IS NOT NULL AND EXISTS (
                    SELECT 1 FROM finance.recurring_payment_keys k
                    WHERE k.key_type = 'counterparty_iban' AND k.key_value = v_iban
                      AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id)))
                AND (CASE WHEN v_shared THEN abs(v_amt - abs(x.e)) <= abs(x.e) * 0.075
                          ELSE v_amt BETWEEN abs(x.e) * 0.5 AND abs(x.e) * 1.5 END))
             OR (v_other IS NOT NULL AND r.target_account_id IS NOT NULL AND x.o = v_other
                 AND v_amt BETWEEN abs(x.e) * 0.5 AND abs(x.e) * 1.5)
             OR (abs(v_amt - abs(x.e)) <= 0.005 AND r.schedule_unit::text = v_unit AND r.schedule_interval = v_int
                 AND (r.schedule_day_of_month IS NULL OR v_dom IS NULL
                      OR LEAST(abs(r.schedule_day_of_month - v_dom), 31 - abs(r.schedule_day_of_month - v_dom)) <= v_tol
                      OR (r.schedule_day_of_month = -1 AND v_dom >= 28) OR (v_dom = -1 AND r.schedule_day_of_month >= 28))
                 AND NOT EXISTS (
                    SELECT 1 FROM finance.recurring_payment_keys k
                    WHERE k.key_type = 'counterparty_iban' AND k.key_value IS DISTINCT FROM v_iban
                      AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id))))
             OR (abs(v_amt - abs(x.e)) <= abs(x.e) * 0.075 AND EXISTS (
                    SELECT 1 FROM regexp_split_to_table(lower(r.name), '[\s,.;:/()_+&-]+') tok
                    WHERE length(tok) >= 4 AND position(tok IN v_txt) > 0)) )) THEN
        RETURN jsonb_build_object('known', true);
    END IF;

    SELECT a.name INTO v_else
    FROM finance.recurring_payments r
    JOIN finance.accounts a ON a.id = r.account_id
    WHERE (r.id IN (SELECT ar.id FROM finance.active_recurring_payments ar)
           OR (r.status = 'active' AND r.valid_from > current_date))
      AND r.account_id <> v_acct AND r.target_account_id IS DISTINCT FROM v_acct
      AND ( (v_iban IS NOT NULL AND EXISTS (
                SELECT 1 FROM finance.recurring_payment_keys k
                WHERE k.key_type = 'counterparty_iban' AND k.key_value = v_iban
                  AND k.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(r.id)))
            AND (CASE WHEN v_shared THEN abs(v_amt - abs(r.amount)) <= abs(r.amount) * 0.075
                      ELSE v_amt BETWEEN abs(r.amount) * 0.5 AND abs(r.amount) * 1.5 END))
         OR (abs(v_amt - abs(r.amount)) <= abs(r.amount) * 0.075 AND EXISTS (
                SELECT 1 FROM regexp_split_to_table(lower(r.name), '[\s,.;:/()_+&-]+') tok
                WHERE length(tok) >= 4 AND position(tok IN v_txt) > 0)) )
    ORDER BY r.id LIMIT 1;
    RETURN jsonb_strip_nulls(jsonb_build_object('known', false, 'elsewhere', v_else));
END;
$$;
