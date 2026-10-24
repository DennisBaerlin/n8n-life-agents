-- ============================================================
-- fn_resolve_savings_plan
--   Loest Sparplan-Name in ID auf (Vorbild: fn_resolve_insurance).
--   Liefert Mehrdeutigkeits-Info (hit_count/candidates).
--   p_active_only: wenn TRUE, nur status='active'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_savings_plan(
    p_name        text,
    p_active_only boolean DEFAULT TRUE
) RETURNS TABLE (
    id          int,
    hit_count   int,
    candidates  jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         INT;
    v_exact      BOOLEAN;
BEGIN
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',      sp.id,
            'name',    sp.name,
            'symbol',  sp.symbol,
            'isin',    sp.isin,
            'status',  sp.status
        ) ORDER BY sp.id),
        COUNT(*),
        MIN(sp.id)
    INTO v_candidates, v_count, v_id
    FROM finance.savings_plans sp
    WHERE finance.fn_name_matches(sp.name, p_name, v_exact)
      AND (p_active_only = FALSE OR sp.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0)::INT,
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
