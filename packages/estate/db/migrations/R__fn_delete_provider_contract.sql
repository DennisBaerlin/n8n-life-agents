-- ============================================================
-- estate.fn_delete_provider_contract (ATOMIC WRITE — WS-2, Hard-DELETE)
--   Loescht einen Vertrag aus dem Register (beendet/Fehlanlage; Vorbild
--   finance.fn_delete_real_estate: Name-Re-Resolve in der fn, 0/>1 Treffer -> {ok:false, code, candidates} statt
--   RAISE — das TOOL loest vor dem Gate auf, die fn ist der Backstop).
--   Keine FK-Referenzen auf provider_contracts -> reines Delete.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, provider (exakt), category (optionaler Filter).
--   RUECKGABE: {ok:true, action:'deleted', provider_contract_id} | {ok:false, reason}.
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_delete_provider_contract.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_delete_provider_contract(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm    TEXT;
    v_prov    TEXT := NULLIF(trim(COALESCE(p->>'provider', '')), '');
    v_resolve RECORD;
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM estate.fn_resolve_provider_contract(v_prov, NULLIF(trim(COALESCE(p->>'category', '')), '')) r;
    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Provider contract "' || COALESCE(v_prov, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple provider contracts match "' || v_prov || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    DELETE FROM estate.provider_contracts WHERE id = v_resolve.id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'provider_contract_id', v_resolve.id);
END;
$$;
