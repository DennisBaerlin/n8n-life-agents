-- ============================================================
-- fn_monitor_validate_fx_rate (READ-ONLY — validate_fn der Monitor-Methode 'fx_rate')
--   Registriert ueber den manifest-Block monitor_acquisition_methods (Phase B, docs/package-contract.md §3.9);
--   der Core dispatcht via agent.fn_monitor_validate_params (Anlage/Aenderung/Probe + BEFORE-Trigger).
--   Prueft + normalisiert das Waehrungspaar: beide Codes Grossbuchstaben, beide in finance.currencies.
--   p: {params: {base, quote}}  (params = Tool-Input acquisition_params bzw. die gespeicherte Spec)
--   RUECKGABE: {ok:true, spec:{base, quote}, display:{kind:'tpl', value:'finance.monitor_display.fx_pair', params}} | {ok:false, reason}
--   Tests: tests/db/finance/test_fn_monitor_validate_fx_rate.sql (+ End-to-end in test_fn_monitor_acquire_fx_rate.sql)
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_monitor_validate_fx_rate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base  text := upper(trim(COALESCE(p->'params'->>'base', '')));
    v_quote text := upper(trim(COALESCE(p->'params'->>'quote', '')));
BEGIN
    IF v_base = '' OR v_quote = '' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'fx_rate needs acquisition_params {"base": "<ISO code>", "quote": "<ISO code>"}, e.g. {"base":"EUR","quote":"KRW"}');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM finance.currencies c WHERE c.code = v_base)
       OR NOT EXISTS (SELECT 1 FROM finance.currencies c WHERE c.code = v_quote) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('unknown currencies for fx_rate: %s/%s — both must be known currencies of the finance package', v_base, v_quote));
    END IF;
    RETURN jsonb_build_object('ok', true,
        'spec', jsonb_build_object('base', v_base, 'quote', v_quote),
        -- Bestaetigungszeile als typisierter Text-Verweis (Textkatalog Phase C): das HITL-Gate rendert sie in der
        -- Sprache des Bestaetigers (finance.monitor_display.fx_pair)
        'display', core.fn_ui_tpl('finance.monitor_display.fx_pair', jsonb_build_object('base', v_base, 'quote', v_quote)));
END;
$$;
