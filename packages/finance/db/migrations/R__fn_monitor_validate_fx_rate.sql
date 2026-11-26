-- ============================================================
-- fn_monitor_validate_fx_rate (READ-ONLY — validate_fn der Monitor-Methode 'fx_rate')
--   Registriert ueber den manifest-Block monitor_acquisition_methods (docs/package-contract.md §3.9);
--   der Core dispatcht via agent.fn_monitor_validate_params (Anlage/Aenderung/Probe + BEFORE-Trigger).
--   Prueft + normalisiert das Paar: beide Codes Grossbuchstaben, beide in finance.currencies. Edelmetalle (fn_is_metal)
--   nur als base (Preis eines Metalls in der Waehrung der Schwelle), dazu die Einheit unit (ozt|g|kg laut
--   fn_metal_unit_factor, Default ozt; bei einem Waehrungspaar abgelehnt). Ein Metall als quote wird abgelehnt und die
--   richtige Richtung genannt: das Modell dreht nicht selbst um und rechnet keine Schwelle um.
--   p: {params: {base, quote, unit?}}  (params = Tool-Input acquisition_params bzw. die gespeicherte Spec)
--   Rueckgabe: {ok:true, spec:{base, quote[, unit]}, display} | {ok:false, reason} (fehlendes base/quote, unbekannte
--   Waehrung, Metall als quote, unit bei Waehrungspaar, unbekannte Einheit). display = typisierter Text-Verweis
--   finance.monitor_display.fx_pair bzw. finance.monitor_display.metal_price (Metall und Einheit als Katalog-Texte).
--   Tests: tests/db/finance/test_fn_monitor_validate_fx_rate.sql (+ End-to-end in test_fn_monitor_acquire_fx_rate.sql)
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_monitor_validate_fx_rate(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_base  text := upper(trim(COALESCE(p->'params'->>'base', '')));
    v_quote text := upper(trim(COALESCE(p->'params'->>'quote', '')));
    v_unit  text := lower(trim(COALESCE(p->'params'->>'unit', '')));
BEGIN
    IF v_base = '' OR v_quote = '' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'fx_rate needs acquisition_params {"base": "<ISO code>", "quote": "<ISO code>"}, e.g. {"base":"EUR","quote":"CLP"} or for gold {"base":"XAU","quote":"EUR","unit":"ozt"}');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM finance.currencies c WHERE c.code = v_base)
       OR NOT EXISTS (SELECT 1 FROM finance.currencies c WHERE c.code = v_quote) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('unknown currencies for fx_rate: %s/%s — both must be known currencies of the finance package', v_base, v_quote));
    END IF;
    IF finance.fn_is_metal(v_quote) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('precious metals are priced as base, never as quote: use {"base":"%s","quote":"%s"} (price of the metal per unit in that currency); keep the user''s threshold unchanged',
                             v_quote, CASE WHEN finance.fn_is_metal(v_base) THEN 'EUR' ELSE v_base END));
    END IF;
    IF NOT finance.fn_is_metal(v_base) THEN
        IF v_unit <> '' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('unit is only for precious metals (base XAU or XAG), not for the currency pair %s/%s', v_base, v_quote));
        END IF;
        RETURN jsonb_build_object('ok', true,
            'spec', jsonb_build_object('base', v_base, 'quote', v_quote),
            -- Bestaetigungszeile als typisierter Text-Verweis (Textkatalog): das HITL-Gate rendert sie in der
            -- Sprache des Bestaetigers (finance.monitor_display.fx_pair)
            'display', core.fn_ui_tpl('finance.monitor_display.fx_pair', jsonb_build_object('base', v_base, 'quote', v_quote)));
    END IF;
    v_unit := COALESCE(NULLIF(v_unit, ''), 'ozt');
    IF finance.fn_metal_unit_factor(v_unit) IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('unknown unit %L for a precious metal: use ozt (troy ounce), g or kg', v_unit));
    END IF;
    RETURN jsonb_build_object('ok', true,
        'spec', jsonb_build_object('base', v_base, 'quote', v_quote, 'unit', v_unit),
        -- Katalog-Keys als volle Literale (locale_lint); ein weiteres Metall braucht hier seinen Namens-Key
        'display', core.fn_ui_tpl('finance.monitor_display.metal_price', jsonb_build_object(
            'metal', CASE v_base WHEN 'XAU' THEN core.fn_ui_tpl('finance.value.metal_xau')
                                 WHEN 'XAG' THEN core.fn_ui_tpl('finance.value.metal_xag')
                                 ELSE to_jsonb(v_base) END,
            'quote', v_quote,
            'unit', CASE v_unit WHEN 'ozt' THEN core.fn_ui_tpl('finance.value.metal_unit_ozt')
                                WHEN 'g'   THEN core.fn_ui_tpl('finance.value.metal_unit_g')
                                ELSE core.fn_ui_tpl('finance.value.metal_unit_kg') END)));
END;
$$;
