-- ============================================================
-- estate.fn_create_digital_account (ATOMIC WRITE — WS-2)
--   Legt ein NEUES Konto des digitalen Nachlasses an — OHNE Passwoerter (Owner-Entscheid 2):
--   access_path/twofa_hint/seed_backup_location sind FUNDORT-Verweise, nie das Geheimnis
--   selbst (Inhalt haerten Tool-Description + Instructions; die DB kann ihn nicht pruefen).
--   seed_backup_location NUR fuer category='crypto' — der Tabellen-CHECK ist das Gesetz,
--   hier die freundliche {ok:false}-Spiegelung. Dubletten-Backstop (Anbieter+Nutzername)
--   faehrt das TOOL vor dem Gate (fn_resolve_digital_account).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   desired_action NULL = bewusst OFFENER Gap. is_key_account: tolerant geparster
--   Wahrheitswert (true/false/yes/no/1/0), Default false.
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalt), category, provider, username,
--     is_key_account, desired_action (delete|memorialize|transfer|keep), access_path,
--     legacy_contact_status (configured|not_configured|unavailable), twofa_hint,
--     seed_backup_location (nur crypto), notes.
--   RUECKGABE: {ok:true, digital_account_id} | {ok:false, reason} (korrigierbar, kein RAISE).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_digital_account.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_digital_account(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_provider TEXT := NULLIF(trim(COALESCE(p->>'provider', '')), '');
    v_category TEXT := lower(NULLIF(trim(COALESCE(p->>'category', '')), ''));
    v_action   TEXT := lower(NULLIF(trim(COALESCE(p->>'desired_action', '')), ''));
    v_legacy   TEXT := lower(NULLIF(trim(COALESCE(p->>'legacy_contact_status', '')), ''));
    v_seed     TEXT := NULLIF(trim(COALESCE(p->>'seed_backup_location', '')), '');
    v_key_raw  TEXT := lower(NULLIF(trim(COALESCE(p->>'is_key_account', '')), ''));
    v_key      BOOLEAN;
    v_id       BIGINT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_provider IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'provider is required (non-empty).');
    END IF;
    IF v_category IS NULL OR v_category NOT IN
        ('email', 'social', 'cloud', 'finance', 'crypto', 'commerce', 'media', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid category "' || COALESCE(v_category, '') || '" — valid: email | social | cloud | finance | crypto | commerce | media | other.');
    END IF;
    IF v_action IS NOT NULL AND v_action NOT IN ('delete', 'memorialize', 'transfer', 'keep') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid desired_action "' || v_action || '" — valid: delete | memorialize | transfer | keep (or omit = open gap).');
    END IF;
    IF v_legacy IS NOT NULL AND v_legacy NOT IN ('configured', 'not_configured', 'unavailable') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid legacy_contact_status "' || v_legacy || '" — valid: configured | not_configured | unavailable (or omit = unknown).');
    END IF;
    -- Freundliche Spiegelung des Tabellen-CHECKs (seed_backup_location ist crypto-gekoppelt):
    IF v_seed IS NOT NULL AND v_category <> 'crypto' THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'seed_backup_location is only valid for category crypto (a seed backup location belongs to a crypto account).');
    END IF;
    -- Toleranter Wahrheitswert (WS-0b-Lektion has_transmortal_poa: "True"/"yes" nicht verlieren):
    v_key := CASE WHEN v_key_raw IN ('true', 'yes', '1', 'ja') THEN TRUE
                  WHEN v_key_raw IN ('false', 'no', '0', 'nein') OR v_key_raw IS NULL THEN FALSE
                  ELSE NULL END;
    IF v_key IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid is_key_account "' || v_key_raw || '" — use true or false.');
    END IF;

    INSERT INTO estate.digital_accounts (owner_person_id, category, provider, username,
                                         is_key_account, desired_action, access_path,
                                         legacy_contact_status, twofa_hint, seed_backup_location, notes)
    VALUES (NULLIF(trim(COALESCE(p->>'owner_person_id', '')), ''), v_category, v_provider,
            NULLIF(trim(COALESCE(p->>'username', '')), ''),
            v_key, v_action,
            NULLIF(trim(COALESCE(p->>'access_path', '')), ''),
            v_legacy,
            NULLIF(trim(COALESCE(p->>'twofa_hint', '')), ''),
            v_seed,
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'digital_account_id', v_id, 'is_key_account', v_key);
END;
$$;
