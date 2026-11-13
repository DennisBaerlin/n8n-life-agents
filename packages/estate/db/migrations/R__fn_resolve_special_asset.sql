-- ============================================================
-- estate.fn_resolve_special_asset (read-only Resolver)
--   Loest einen Sonderfall-Stub ueber die Beschreibung (exakt) + optional den Typ auf
--   (Muster: finance.fn_resolve_real_estate). Die Beschreibung ist der einzige Frei-Identifikator
--   der Stubs — der Agent liest sie vorher exakt aus dem Register (Register-first-Vertrag der Instructions).
--   Eingabe: p_description, p_asset_type (NULL/'' = nicht filtern). Rueckgabe: Zeile (id, hit_count,
--   candidates); id nur bei genau einem Treffer, sonst NULL; candidates =
--   [{id,asset_type,description,owner_person_id}] (leer: []).
--   Genutzt von tool_delete_special_asset (Pre-Gate-Resolve) + als Dubletten-Backstop
--   in tool_create_special_asset.
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_resolve_special_asset(
    p_description text,
    p_asset_type  text DEFAULT NULL
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
            'asset_type',      s.asset_type,
            'description',     s.description,
            'owner_person_id', s.owner_person_id
        ) ORDER BY s.id),
        COUNT(*),
        MIN(s.id)
    INTO v_candidates, v_count, v_id
    FROM estate.special_assets s
    WHERE s.description = p_description
      AND (p_asset_type IS NULL OR p_asset_type = '' OR s.asset_type = p_asset_type);

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
