-- ============================================================
-- estate.fn_resolve_storage_place (read-only Resolver, WS-2)
--   Loest eine Fundstelle ueber den Namen (exakt) auf (Vorbild: finance.fn_resolve_real_estate;
--   Rueckgabe id/hit_count/candidates). Genutzt von tool_set_storage_place (Pre-Gate-Resolve),
--   als Dubletten-Backstop in tool_create_storage_place UND in-fn von estate.fn_record_directive
--   (optionale storage_place_name-Aufloesung -> {ok:false} statt RAISE bei 0/>1).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_resolve_storage_place.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_resolve_storage_place(
    p_name text
) RETURNS TABLE (
    id         bigint,
    hit_count  int,
    candidates jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_candidates JSONB;
    v_count      INT;
    v_id         BIGINT;
BEGIN
    SELECT
        jsonb_agg(jsonb_build_object(
            'id',              s.id,
            'name',            s.name,
            'kind',            s.kind,
            'location',        s.location,
            'owner_person_id', s.owner_person_id
        ) ORDER BY s.id),
        COUNT(*),
        MIN(s.id)
    INTO v_candidates, v_count, v_id
    FROM estate.storage_places s
    WHERE s.name = p_name;

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
