-- ============================================================
-- estate.fn_set_storage_place (ATOMIC WRITE — WS-2, partielles UPDATE)
--   Aendert eine bestehende Fundstelle ("nicht gesendet = unveraendert"). Fundstellen sind
--   FK-Ziel von estate.directives (RESTRICT) — es gibt bewusst KEIN delete_storage_place in
--   WS-2; eine obsolete Fundstelle wird hier umbenannt/umgewidmet. access_hint bleibt ein
--   Fundort-Verweis OHNE Codes/PINs (Owner-Entscheid 2). Die ID loest das TOOL vor dem Gate
--   via estate.fn_resolve_storage_place auf; not-found hier = echte Ausnahme (RAISE).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, storage_place_id, new_name, new_kind, location, access_hint, notes.
--   RUECKGABE: {ok:true, storage_place_id} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_storage_place.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_storage_place(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm TEXT;
    v_id   BIGINT := (p->>'storage_place_id')::bigint;
    v_kind TEXT := lower(NULLIF(trim(COALESCE(p->>'new_kind', '')), ''));
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM estate.storage_places WHERE id = v_id) THEN
        RAISE EXCEPTION 'Storage place % not found.', v_id;
    END IF;
    IF v_kind IS NOT NULL AND v_kind NOT IN ('safe', 'bank_deposit_box', 'folder', 'digital', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid new_kind "' || v_kind || '" — valid: safe | bank_deposit_box | folder | digital | other.');
    END IF;

    UPDATE estate.storage_places SET
        name        = COALESCE(NULLIF(trim(COALESCE(p->>'new_name', '')), ''), name),
        kind        = COALESCE(v_kind, kind),
        location    = COALESCE(NULLIF(trim(COALESCE(p->>'location', '')), ''), location),
        access_hint = COALESCE(NULLIF(trim(COALESCE(p->>'access_hint', '')), ''), access_hint),
        notes       = COALESCE(NULLIF(trim(COALESCE(p->>'notes', '')), ''), notes)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'storage_place_id', v_id);
END;
$$;
