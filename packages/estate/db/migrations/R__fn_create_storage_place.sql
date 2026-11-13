-- ============================================================
-- estate.fn_create_storage_place (ATOMIC WRITE)
--   Legt eine neue Fundstelle an (Tresor/Bankschliessfach/Ordner/digital). access_hint =
--   wie man rankommt ("Schluessel im Sekretaer") — nie Codes/PINs (Inhalt
--   haerten Tool-Description + Instructions). Fundstellen sind FK-Ziel von estate.directives
--   (RESTRICT) — deshalb gibt es kein delete_storage_place (Repurpose via
--   set_storage_place). Dubletten-Backstop (Name) faehrt das Tool vor dem Gate.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalts-Fundstelle), name (Pflicht),
--     kind (Pflicht: safe|bank_deposit_box|folder|digital|other), location, access_hint, notes.
--   Rueckgabe: {ok:true, storage_place_id} | {ok:false, reason} (korrigierbar, kein RAISE); reasons: 'Write rejected
--   (<perm>): …', 'name is required (non-empty).', 'invalid kind "<k>" — valid: …'.
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_storage_place(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm TEXT;
    v_name TEXT := NULLIF(trim(COALESCE(p->>'name', '')), '');
    v_kind TEXT := lower(NULLIF(trim(COALESCE(p->>'kind', '')), ''));
    v_id   BIGINT;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF v_name IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'name is required (non-empty).');
    END IF;
    IF v_kind IS NULL OR v_kind NOT IN ('safe', 'bank_deposit_box', 'folder', 'digital', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid kind "' || COALESCE(v_kind, '') || '" — valid: safe | bank_deposit_box | folder | digital | other.');
    END IF;

    INSERT INTO estate.storage_places (owner_person_id, name, kind, location, access_hint, notes)
    VALUES (NULLIF(trim(COALESCE(p->>'owner_person_id', '')), ''), v_name, v_kind,
            NULLIF(trim(COALESCE(p->>'location', '')), ''),
            NULLIF(trim(COALESCE(p->>'access_hint', '')), ''),
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'storage_place_id', v_id);
END;
$$;
