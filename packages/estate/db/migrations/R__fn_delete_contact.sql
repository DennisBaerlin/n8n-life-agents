-- ============================================================
-- estate.fn_delete_contact (ATOMIC WRITE — WS-2, Hard-DELETE)
--   Loescht einen Schluessel-Kontakt aus dem Register (obsolet/Fehlanlage; Vorbild
--   finance.fn_delete_real_estate: Name-Re-Resolve, 0/>1 Treffer -> {ok:false, code, candidates} (Probelauf vor der Karte) — das TOOL
--   loest vor dem Gate auf). Keine FK-Referenzen -> reines Delete.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, name (exakt), role (optionaler Filter).
--   RUECKGABE: {ok:true, action:'deleted', contact_id} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_delete_contact.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_delete_contact(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_name    TEXT := NULLIF(trim(COALESCE(p->>'name', '')), '');
    v_resolve RECORD;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM estate.fn_resolve_contact(v_name, NULLIF(trim(COALESCE(p->>'role', '')), '')) r;
    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Contact "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple contacts match "' || v_name || '" - ask the user which one (role) (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    DELETE FROM estate.contacts WHERE id = v_resolve.id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'contact_id', v_resolve.id);
END;
$$;
