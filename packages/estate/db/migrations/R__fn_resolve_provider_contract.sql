-- ============================================================
-- estate.fn_resolve_provider_contract (read-only Resolver, WS-2)
--   Loest einen Vertrag ueber den Anbieter-Namen (exakt) + optional die Kategorie auf
--   (Vorbild: finance.fn_resolve_real_estate; Rueckgabe id/hit_count/candidates — bei
--   hit_count <> 1 praesentiert das Tool die Kandidaten statt zu schreiben).
--   p_category NULL = nicht filtern. Genutzt von tool_set_/delete_provider_contract
--   (Pre-Gate-Resolve) + als Dubletten-Backstop in tool_create_provider_contract.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_resolve_provider_contract.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_resolve_provider_contract(
    p_provider text,
    p_category text DEFAULT NULL
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
            'provider',        c.provider,
            'category',        c.category,
            'customer_no',     c.customer_no,
            'owner_person_id', c.owner_person_id
        ) ORDER BY c.id),
        COUNT(*),
        MIN(c.id)
    INTO v_candidates, v_count, v_id
    FROM estate.provider_contracts c
    WHERE c.provider = p_provider
      AND (p_category IS NULL OR p_category = '' OR c.category = p_category);

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
