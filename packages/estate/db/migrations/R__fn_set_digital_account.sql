-- ============================================================
-- estate.fn_set_digital_account (ATOMIC WRITE — WS-2, partielles UPDATE)
--   Aendert ein bestehendes Konto des digitalen Nachlasses ("nicht gesendet = unveraendert").
--   Die ID loest das TOOL vor dem Gate via estate.fn_resolve_digital_account auf; not-found
--   hier = echte Ausnahme (RAISE). NIE Passwoerter — alle Zugangs-Felder sind Fundort-Verweise.
--   seed_backup_location bleibt crypto-gekoppelt: die freundliche Spiegelung prueft gegen die
--   EFFEKTIVE Kategorie (neu ODER bestehend); der Tabellen-CHECK ist der Backstop.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, digital_account_id, new_provider, new_username, new_category,
--     is_key_account (true|false), desired_action, access_path, legacy_contact_status,
--     twofa_hint, seed_backup_location, notes.
--   RUECKGABE: {ok:true, digital_account_id} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_digital_account.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_digital_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_id       BIGINT := (p->>'digital_account_id')::bigint;
    v_category TEXT := lower(NULLIF(trim(COALESCE(p->>'new_category', '')), ''));
    v_action   TEXT := lower(NULLIF(trim(COALESCE(p->>'desired_action', '')), ''));
    v_legacy   TEXT := lower(NULLIF(trim(COALESCE(p->>'legacy_contact_status', '')), ''));
    v_seed     TEXT := NULLIF(trim(COALESCE(p->>'seed_backup_location', '')), '');
    v_key_raw  TEXT := lower(NULLIF(trim(COALESCE(p->>'is_key_account', '')), ''));
    v_key      BOOLEAN;
    v_eff_cat  TEXT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM estate.digital_accounts WHERE id = v_id) THEN
        RAISE EXCEPTION 'Digital account % not found.', v_id;
    END IF;
    IF v_category IS NOT NULL AND v_category NOT IN
        ('email', 'social', 'cloud', 'finance', 'crypto', 'commerce', 'media', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid new_category "' || v_category || '" — valid: email | social | cloud | finance | crypto | commerce | media | other.');
    END IF;
    IF v_action IS NOT NULL AND v_action NOT IN ('delete', 'memorialize', 'transfer', 'keep') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid desired_action "' || v_action || '" — valid: delete | memorialize | transfer | keep.');
    END IF;
    IF v_legacy IS NOT NULL AND v_legacy NOT IN ('configured', 'not_configured', 'unavailable') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid legacy_contact_status "' || v_legacy || '" — valid: configured | not_configured | unavailable.');
    END IF;
    IF v_key_raw IS NOT NULL THEN
        v_key := CASE WHEN v_key_raw IN ('true', 'yes', '1', 'ja') THEN TRUE
                      WHEN v_key_raw IN ('false', 'no', '0', 'nein') THEN FALSE
                      ELSE NULL END;
        IF v_key IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'invalid is_key_account "' || v_key_raw || '" — use true or false.');
        END IF;
    END IF;
    -- Effektive Kategorie (neu > bestehend) fuer die crypto-Kopplung des Seed-Fundorts:
    SELECT COALESCE(v_category, a.category) INTO v_eff_cat FROM estate.digital_accounts a WHERE a.id = v_id;
    IF v_seed IS NOT NULL AND v_eff_cat <> 'crypto' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'seed_backup_location is only valid for category crypto (effective category is ' || v_eff_cat || ').');
    END IF;

    UPDATE estate.digital_accounts SET
        provider              = COALESCE(NULLIF(trim(COALESCE(p->>'new_provider', '')), ''), provider),
        username              = COALESCE(NULLIF(trim(COALESCE(p->>'new_username', '')), ''), username),
        category              = COALESCE(v_category, category),
        is_key_account        = COALESCE(v_key, is_key_account),
        desired_action        = COALESCE(v_action, desired_action),
        access_path           = COALESCE(NULLIF(trim(COALESCE(p->>'access_path', '')), ''), access_path),
        legacy_contact_status = COALESCE(v_legacy, legacy_contact_status),
        twofa_hint            = COALESCE(NULLIF(trim(COALESCE(p->>'twofa_hint', '')), ''), twofa_hint),
        seed_backup_location  = COALESCE(v_seed, seed_backup_location),
        notes                 = COALESCE(NULLIF(trim(COALESCE(p->>'notes', '')), ''), notes)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'digital_account_id', v_id);
END;
$$;
