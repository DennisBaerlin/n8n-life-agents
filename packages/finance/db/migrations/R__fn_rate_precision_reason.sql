-- ============================================================
-- fn_rate_precision_reason (READ HELPER) -- Zinssatz/Tilgung passt in numeric(6,4) (Rundungs-Paket 2026-10-23)
--   EINE Adresse fuer fn_create_account, fn_interest_rate_preview (set_account_interest + Karte), fn_create_loan und
--   fn_set_loan. NULL = ok (auch bei NULL-Satz), sonst der korrigierbare Grund (EN):
--     * mehr als 4 Nachkommastellen: account_interest_rates.annual_rate / loans.interest_rate sind
--       numeric(6,4) und kuerzten still (3.12345 -> 3.1235). Geprueft per round(p,4) statt scale(): 3.50000 ist ok.
--     * |Satz| >= 100: numeric(6,4) wuerde mit Overflow-RAISE abbrechen.
--   Bewusst kein Spalten-Umbau: loans.interest_rate speist Views und Zins-fns; der Rest-Fehler von <= 0.00005
--   Prozentpunkten ist ohne Wirkung, wichtig ist, dass nichts STILL geaendert wird.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_rate_precision_reason(p_rate numeric, p_field text)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
BEGIN
    IF p_rate IS NULL THEN RETURN NULL; END IF;
    IF abs(p_rate) >= 100 THEN
        RETURN p_field || ' ' || p_rate || ' is out of range - give it in percent per year below 100 (e.g. 3.5).';
    END IF;
    IF p_rate <> round(p_rate, 4) THEN
        RETURN p_field || ' ' || p_rate || ' has more than 4 decimal places - give it with at most 4 (e.g. 3.1235).';
    END IF;
    RETURN NULL;
END;
$$;
