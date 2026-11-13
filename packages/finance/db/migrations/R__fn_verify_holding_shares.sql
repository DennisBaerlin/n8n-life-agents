-- ============================================================
-- fn_verify_holding_shares (READ, STABLE)
--   Self-Check nach Buy/Sell: stimmt shares mit Erwartung ueberein?
--   Eingabe: p_holding_id, p_expected (erwartete Stueckzahl).
--   TRUE = passt, FALSE = Drift (Helper wirft Error); NULL bei unbekannter holding_id.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_verify_holding_shares(
    p_holding_id int,
    p_expected   numeric
) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT shares = p_expected FROM finance.depot_holdings WHERE id = p_holding_id;
$$;
