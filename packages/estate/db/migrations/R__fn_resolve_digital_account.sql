-- ============================================================
-- estate.fn_resolve_digital_account (read-only Resolver, WS-2)
--   Loest ein digitales Konto ueber den Anbieter-Namen (exakt) + optional den Nutzernamen auf
--   (Vorbild: finance.fn_resolve_real_estate; Rueckgabe id/hit_count/candidates). Zwei Konten
--   beim selben Anbieter (z. B. je Partner ein Google-Konto) disambiguiert der Nutzername.
--   Genutzt von tool_set_/delete_digital_account (Pre-Gate-Resolve) + als Dubletten-Backstop
--   in tool_create_digital_account.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_resolve_digital_account.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_resolve_digital_account(
    p_provider text,
    p_username text DEFAULT NULL
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
            'id',              a.id,
            'provider',        a.provider,
            'username',        a.username,
            'category',        a.category,
            'is_key_account',  a.is_key_account,
            'owner_person_id', a.owner_person_id
        ) ORDER BY a.id),
        COUNT(*),
        MIN(a.id)
    INTO v_candidates, v_count, v_id
    FROM estate.digital_accounts a
    WHERE a.provider = p_provider
      AND (p_username IS NULL OR p_username = '' OR a.username = p_username);

    RETURN QUERY SELECT
        CASE WHEN v_count = 1 THEN v_id ELSE NULL END,
        COALESCE(v_count, 0),
        COALESCE(v_candidates, '[]'::jsonb);
END;
$$;
