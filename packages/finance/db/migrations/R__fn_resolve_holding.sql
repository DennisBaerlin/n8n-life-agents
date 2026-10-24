-- ============================================================
-- fn_resolve_holding
--   Holding im konkreten Depot finden. Liefert found=FALSE wenn nicht vorhanden
--   (Helper weiss dann: erst INSERT, dann buchen).
-- ============================================================
-- Drop the old 2-arg overload so the 3-arg version is unambiguous.
DROP FUNCTION IF EXISTS finance.fn_resolve_holding(int, text);

CREATE OR REPLACE FUNCTION finance.fn_resolve_holding(
    p_depot_id  int,
    p_isin      text,            -- NULL (or '') for crypto
    p_symbol    text DEFAULT NULL
) RETURNS TABLE (
    id        int,
    shares    numeric,
    avg_price numeric,
    found     boolean
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_isin TEXT := NULLIF(p_isin, '');
BEGIN
    -- ISIN-based lookup for stocks/ETFs; symbol-based for crypto (isin IS NULL).
    RETURN QUERY
    SELECT
        h.id,
        h.shares,
        h.average_purchase_price,
        TRUE
    FROM finance.depot_holdings h
    WHERE h.account_id = p_depot_id
      AND (
          (v_isin IS NOT NULL AND h.isin = v_isin)
          OR (v_isin IS NULL AND h.isin IS NULL AND h.symbol = p_symbol)
      )
    UNION ALL
    SELECT NULL::INT, NULL::NUMERIC, NULL::NUMERIC, FALSE
    WHERE NOT EXISTS (
        SELECT 1 FROM finance.depot_holdings h
        WHERE h.account_id = p_depot_id
          AND (
              (v_isin IS NOT NULL AND h.isin = v_isin)
              OR (v_isin IS NULL AND h.isin IS NULL AND h.symbol = p_symbol)
          )
    )
    LIMIT 1;
END;
$$;
