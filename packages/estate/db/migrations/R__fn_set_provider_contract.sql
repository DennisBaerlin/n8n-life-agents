-- ============================================================
-- estate.fn_set_provider_contract (ATOMIC WRITE — WS-2, partielles UPDATE)
--   Aendert einen bestehenden Nicht-finance-Vertrag ("nicht gesendet = unveraendert",
--   COALESCE-Idiom wie finance.fn_set_real_estate). Die ID loest das TOOL vor dem Gate via
--   estate.fn_resolve_provider_contract auf (0/>1 -> Tool-Rueckfrage); not-found hier =
--   echte Ausnahme (RAISE — der Resolve haette greifen muessen).
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   Eingabe jsonb: chat_id, provider_contract_id, new_provider, new_category, customer_no,
--     contract_no, contact_info, death_action (cancel|transfer|keep), notes.
--   RUECKGABE: {ok:true, provider_contract_id} | {ok:false, reason} (korrigierbar).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_set_provider_contract.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_set_provider_contract(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_id       BIGINT := (p->>'provider_contract_id')::bigint;
    v_category TEXT := lower(NULLIF(trim(COALESCE(p->>'new_category', '')), ''));
    v_action   TEXT := lower(NULLIF(trim(COALESCE(p->>'death_action', '')), ''));
BEGIN
    v_perm := core.fn_check_write_permission('adults_only', p->>'chat_id', NULL);
    IF v_perm IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Write rejected (' || v_perm || '): only adult household members (owner/partner) may write to the estate register.');
    END IF;

    IF NOT EXISTS (SELECT 1 FROM estate.provider_contracts WHERE id = v_id) THEN
        RAISE EXCEPTION 'Provider contract % not found.', v_id;
    END IF;
    IF v_category IS NOT NULL AND v_category NOT IN
        ('utilities', 'telecom', 'media', 'subscription', 'membership', 'housing', 'mobility', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid new_category "' || v_category || '" — valid: utilities | telecom | media | subscription | membership | housing | mobility | other.');
    END IF;
    IF v_action IS NOT NULL AND v_action NOT IN ('cancel', 'transfer', 'keep') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid death_action "' || v_action || '" — valid: cancel | transfer | keep.');
    END IF;

    UPDATE estate.provider_contracts SET
        provider     = COALESCE(NULLIF(trim(COALESCE(p->>'new_provider', '')), ''), provider),
        category     = COALESCE(v_category, category),
        customer_no  = COALESCE(NULLIF(trim(COALESCE(p->>'customer_no', '')), ''), customer_no),
        contract_no  = COALESCE(NULLIF(trim(COALESCE(p->>'contract_no', '')), ''), contract_no),
        contact_info = COALESCE(NULLIF(trim(COALESCE(p->>'contact_info', '')), ''), contact_info),
        death_action = COALESCE(v_action, death_action),
        notes        = COALESCE(NULLIF(trim(COALESCE(p->>'notes', '')), ''), notes)
    WHERE id = v_id;

    RETURN jsonb_build_object('ok', true, 'provider_contract_id', v_id);
END;
$$;
