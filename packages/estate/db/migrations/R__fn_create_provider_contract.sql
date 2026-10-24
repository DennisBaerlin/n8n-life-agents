-- ============================================================
-- estate.fn_create_provider_contract (ATOMIC WRITE — WS-2)
--   Legt einen NEUEN Nicht-finance-Vertrag im Register an (Energie/Telekom/Abo/Verein/Wohnen;
--   Versicherungs-/Konto-Stammdaten leben bei FINANCE — Grenzregel). Den deterministischen
--   Dubletten-Backstop (gleicher Anbieter + Kategorie) faehrt das TOOL vor dem Gate
--   (fn_resolve_provider_contract, create_*-Pflicht-Node); Aenderungen -> set_provider_contract.
--   DB-Backstop: core.fn_check_write_permission('adults_only', chat_id) — Kind -> {ok:false}.
--   death_action NULL = bewusst OFFENER Gap (die Gap-Analyse nudgt darauf).
--   finance_recurring_payment_id: lose Referenz OHNE FK (stale = Gap-Anzeige, nie Crash);
--   das WS-2-Tool sendet sie nicht (der estate-Agent liest finance nicht) — der Key bleibt
--   fuer privilegierte Aufrufer lesbar.
--   Eingabe jsonb: chat_id, owner_person_id (Slug, ''=Haushalt), category, provider,
--     customer_no, contract_no, contact_info, death_action (cancel|transfer|keep),
--     finance_recurring_payment_id, notes.
--   RUECKGABE: {ok:true, provider_contract_id} | {ok:false, reason} (korrigierbar, kein RAISE).
--   Anwenden via: db_apply.ps1 -File packages\estate\db\migrations\R__fn_create_provider_contract.sql
-- ============================================================
CREATE OR REPLACE FUNCTION estate.fn_create_provider_contract(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_perm     TEXT;
    v_provider TEXT := NULLIF(trim(COALESCE(p->>'provider', '')), '');
    v_category TEXT := lower(NULLIF(trim(COALESCE(p->>'category', '')), ''));
    v_action   TEXT := lower(NULLIF(trim(COALESCE(p->>'death_action', '')), ''));
    v_rp_id    BIGINT;
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
        ('utilities', 'telecom', 'media', 'subscription', 'membership', 'housing', 'mobility', 'other') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid category "' || COALESCE(v_category, '') || '" — valid: utilities | telecom | media | subscription | membership | housing | mobility | other.');
    END IF;
    IF v_action IS NOT NULL AND v_action NOT IN ('cancel', 'transfer', 'keep') THEN
        RETURN jsonb_build_object('ok', false, 'reason',
            'invalid death_action "' || v_action || '" — valid: cancel | transfer | keep (or omit = open gap).');
    END IF;
    -- Lose finance-Referenz: nur eine ECHTE Zahl uebernehmen (kein Cast-RAISE auf Muell).
    IF COALESCE(p->>'finance_recurring_payment_id', '') ~ '^[0-9]+$' THEN
        v_rp_id := (p->>'finance_recurring_payment_id')::bigint;
    END IF;

    INSERT INTO estate.provider_contracts (owner_person_id, category, provider, customer_no,
                                           contract_no, contact_info, death_action,
                                           finance_recurring_payment_id, notes)
    VALUES (NULLIF(trim(COALESCE(p->>'owner_person_id', '')), ''), v_category, v_provider,
            NULLIF(trim(COALESCE(p->>'customer_no', '')), ''),
            NULLIF(trim(COALESCE(p->>'contract_no', '')), ''),
            NULLIF(trim(COALESCE(p->>'contact_info', '')), ''),
            v_action, v_rp_id,
            NULLIF(trim(COALESCE(p->>'notes', '')), ''))
    RETURNING id INTO v_id;

    RETURN jsonb_build_object('ok', true, 'provider_contract_id', v_id);
END;
$$;
