-- ============================================================
-- fn_resolve_savings_goal
--   Loest Sparziel-Name in ID auf (Vorbild fn_resolve_account).
--   p_active_only: default TRUE -> nur status='active'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_savings_goal(
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
            'id',            g.id,
            'name',          g.name,
            'target_amount', g.target_amount,
            'target_date',   g.target_date,
            'status',        g.status
        ) ORDER BY g.id),
        COUNT(*),
        MIN(g.id)
    INTO v_candidates, v_count, v_id
    FROM finance.savings_goals g
    WHERE finance.fn_name_matches(g.name, p_name, v_exact)
      AND (p_active_only = FALSE OR g.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
