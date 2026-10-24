-- ============================================================
-- estate.fn_resolve_contact (read-only Resolver, WS-2)
--   Loest einen Schluessel-Kontakt ueber den Namen (exakt) + optional die Rolle auf
--   (Vorbild: finance.fn_resolve_real_estate; Rueckgabe id/hit_count/candidates).
--   Genutzt von tool_set_/delete_contact (Pre-Gate-Resolve) + als Dubletten-Backstop
--   in tool_create_contact.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_resolve_contact.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_resolve_contact(
    p_name text,
    p_role text DEFAULT NULL
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
            'id',              c.id,
            'name',            c.name,
            'role',            c.role,
            'organization',    c.organization,
            'owner_person_id', c.owner_person_id
        ) ORDER BY c.id),
        COUNT(*),
        MIN(c.id)
    INTO v_candidates, v_count, v_id
    FROM estate.contacts c
    WHERE c.name = p_name
      AND (p_role IS NULL OR p_role = '' OR c.role = p_role);

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
