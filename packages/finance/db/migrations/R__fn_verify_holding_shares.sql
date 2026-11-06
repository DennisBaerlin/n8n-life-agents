-- ============================================================
-- fn_verify_holding_shares
--   Self-Check nach Buy/Sell: stimmt shares mit Erwartung ueberein?
--   TRUE = passt, FALSE = Drift (Helper wirft Error).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_verify_holding_shares(
    p_holding_id int,
    p_expected   numeric
) RETURNS boolean LANGUAGE sql STABLE AS $$
    SELECT shares = p_expected FROM finance.depot_holdings WHERE id = p_holding_id;
$$;
