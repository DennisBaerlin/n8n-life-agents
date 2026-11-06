-- ============================================================
-- estate.fn_delete_special_asset (ATOMIC WRITE — WS-2, Hard-DELETE)
--   Loescht einen Sonderfall-Stub (verkauft/abgegeben/Fehlanlage — special_assets haben
--   keinen Lifecycle-Status; ein verkauftes Fahrzeug MUSS raus, sonst instanziiert der
--   WS-3-Ereignisfall falsche Checklisten-Tasks). Vorbild finance.fn_delete_real_estate:
--   Beschreibungs-Re-Resolve, 0/>1 Treffer -> {ok:false, code, candidates} (Probelauf vor der Karte) — das TOOL loest vor dem Gate auf.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, description (exakt), asset_type (optionaler Filter).
--   RUECKGABE: {ok:true, action:'deleted', special_asset_id} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_delete_special_asset.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_delete_special_asset(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_desc    TEXT := NULLIF(trim(COALESCE(p->>'description', '')), '');
    v_resolve RECORD;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM estate.fn_resolve_special_asset(v_desc, NULLIF(trim(COALESCE(p->>'asset_type', '')), '')) r;
    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Special asset "' || COALESCE(v_desc, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple special assets match "' || v_desc || '" - ask the user which one (asset_type) (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    DELETE FROM estate.special_assets WHERE id = v_resolve.id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'special_asset_id', v_resolve.id);
END;
$$;
