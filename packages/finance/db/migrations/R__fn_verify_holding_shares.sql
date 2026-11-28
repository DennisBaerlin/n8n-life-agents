-- ============================================================
-- fn_verify_holding_shares (READ, STABLE)
--   Self-Check: stimmt shares mit Erwartung ueberein? Derzeit ruft sie nur tests/db/finance/test_fn_verify_holding_shares.sql.
--   Eingabe: p_holding_id, p_expected (erwartete Stueckzahl).
--   TRUE = passt, FALSE = Drift; NULL bei unbekannter holding_id.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_verify_holding_shares(
    p_holding_id int,
    p_expected   numeric
) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT shares = p_expected FROM finance.depot_holdings WHERE id = p_holding_id;
$$;
