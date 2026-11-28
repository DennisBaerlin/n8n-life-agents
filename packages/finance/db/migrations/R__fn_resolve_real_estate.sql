-- ============================================================
-- fn_resolve_real_estate (READ, STABLE)
--   Loest Immobilien-Name in ID auf (Vorbild: fn_resolve_account).
--   Liefert Mehrdeutigkeits-Info (hit_count/candidates), damit das Tool
--   bei hit_count > 1 dem Nutzer die Treffer praesentieren kann.
--   Rueckgabe: TABLE(id, hit_count, candidates); id nur bei genau einem Treffer.
--   p_active_only: TRUE (Default) = nur status='active'; FALSE = alle; NULL = aktive zuerst, ohne aktiven Treffer alle
--     (Aendern-Werkzeuge: eine pausierte oder beendete Sache bleibt auffindbar, eine aktive gleichen Namens gewinnt, auch bei anderer
--     Gross-/Kleinschreibung).
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
    v_act        BOOLEAN;
BEGIN
    FOREACH v_act IN ARRAY CASE WHEN p_active_only IS NULL THEN ARRAY[TRUE, FALSE] ELSE ARRAY[p_active_only] END LOOP
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',     re.id,
            'name',   re.name,
            'owner_person_id', re.owner_person_id,   -- NULL = Haushalt
            'status', re.status
        ) ORDER BY re.id),
        COUNT(*),
        MIN(re.id)
    INTO v_candidates, v_count, v_id
    FROM finance.real_estate re
    WHERE finance.fn_name_matches(re.name, p_name, v_exact)
      AND (NOT v_act OR re.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;
    EXIT WHEN v_count > 0;
    END LOOP;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
