-- ============================================================
-- fn_resolve_real_estate
--   Loest Immobilien-Name in ID auf (Vorbild: fn_resolve_account).
--   Liefert Mehrdeutigkeits-Info (hit_count/candidates), damit das Tool
--   bei hit_count > 1 dem Nutzer die Treffer praesentieren kann.
--   p_active_only: wenn TRUE, nur status='active'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_real_estate(
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
            'id',     re.id,
            'name',   re.name,
            'owner_person_id', re.owner_person_id,   -- WS-4: Freitext-owner abgeloest (NULL=Haushalt)
            'status', re.status
        ) ORDER BY re.id),
        COUNT(*),
        MIN(re.id)
    INTO v_candidates, v_count, v_id
    FROM finance.real_estate re
    WHERE finance.fn_name_matches(re.name, p_name, v_exact)
      AND (p_active_only = FALSE OR re.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
