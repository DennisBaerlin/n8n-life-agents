-- ============================================================
-- fn_resolve_insurance (READ, STABLE)
--   Loest Versicherungs-Name in ID auf (Vorbild: fn_resolve_account).
--   Liefert Mehrdeutigkeits-Info (hit_count/candidates).
--   Rueckgabe: TABLE(id, hit_count, candidates); id nur bei genau einem Treffer.
--   p_active_only: TRUE (Default) = nur status='active'; FALSE = alle; NULL = aktive zuerst, ohne aktiven Treffer alle
--     (Aendern-Werkzeuge: eine pausierte oder beendete Sache bleibt auffindbar, eine aktive gleichen Namens gewinnt).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_resolve_insurance(
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
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    FOREACH v_act IN ARRAY CASE WHEN p_active_only IS NULL THEN ARRAY[TRUE, FALSE] ELSE ARRAY[p_active_only] END LOOP
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',                i.id,
            'name',              i.name,
            'insurance_company', i.insurance_company,
            'status',            i.status
        ) ORDER BY i.id),
        COUNT(*),
        MIN(i.id)
    INTO v_candidates, v_count, v_id
    FROM finance.insurances i
    WHERE finance.fn_name_matches(i.name, p_name, v_exact)
      AND (NOT v_act OR i.status = 'active');
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
