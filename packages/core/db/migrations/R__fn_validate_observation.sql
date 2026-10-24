-- ============================================================
-- fn_validate_observation (IMMUTABLE HELPER — geteilte Validierungs-Kaskade)
--   Die EINE Quelle der Wert-Validierung fuer beschaffte Observations — genutzt von
--   fn_monitor_evaluate (Cron) UND fn_monitor_probe (Test-Abruf vor dem HITL-Gate).
--   Kaskade (Stufen 2-4; Stufe 1 = struktureller JSON-Parse im Workflow-Code-Node):
--     (0) input ok=false wird durchgereicht (Beschaffung selbst schlug fehl)
--     (1) value muss numerisch sein (LLM-Prosa wie "ca. 4000" -> dirty)
--     (2) Unit-Echo: NUR web_search + expected_unit gesetzt — geliefertes unit muss
--         case-/trim-tolerant matchen (faengt $/oz-vs-EUR/oz und oz-vs-g, was statische
--         Bounds NICHT fangen); sql/fx haben kein Echo (expected_unit = Render-Label)
--     (3) statische Plausibilitaet min/max_plausible (Groessenordnungs-Fehler)
--     (4) Kontinuitaet max_jump_pct (optional): Abweichung > X% vom letzten SAUBEREN
--         Wert -> dirty (Quelle gewechselt / Skala verrutscht); kein last_value
--         (erster Wert) oder Guard NULL -> Stufe uebersprungen
--   p_method='none' (reiner Reminder) -> immer ok, kein Wert noetig.
--   Rueckgabe: normalisierte Observation {ok, value?, unit?, as_of?, source_url?, reason?}
--   — value ist nur enthalten, wenn numerisch (Aufrufer duerfen blind ::numeric casten).
--   Fn-intern (positional), kein Tool-facing {ok:false}-Vertrag noetig.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_validate_observation(
    p_obs           jsonb,
    p_method        text,
    p_expected_unit text,
    p_min           numeric,
    p_max           numeric,
    p_jump_pct      numeric,
    p_last          numeric
) RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_value  NUMERIC;
    v_unit   TEXT := p_obs->>'unit';
    v_as_of  TEXT := p_obs->>'as_of';
    v_src    TEXT := p_obs->>'source_url';
BEGIN
    -- Reiner Reminder: nichts zu validieren
    IF p_method = 'none' THEN
        RETURN jsonb_build_object('ok', true);
    END IF;

    -- (0) Beschaffung selbst fehlgeschlagen -> durchreichen
    IF COALESCE((p_obs->>'ok')::boolean, false) IS DISTINCT FROM true THEN
        RETURN jsonb_strip_nulls(jsonb_build_object(
            'ok', false,
            'reason', COALESCE(NULLIF(trim(p_obs->>'reason'), ''), 'acquisition failed without reason'),
            'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
    END IF;

    -- (1) numerischer Wert
    BEGIN
        v_value := (p_obs->>'value')::numeric;
    EXCEPTION WHEN OTHERS THEN
        v_value := NULL;
    END;
    IF v_value IS NULL THEN
        RETURN jsonb_strip_nulls(jsonb_build_object(
            'ok', false, 'reason', 'no numeric value: ' || COALESCE(left(p_obs->>'value', 80), 'null'),
            'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
    END IF;

    -- (2) Unit-Echo (nur Werte aus dem Internet)
    IF p_method = 'web_search' AND p_expected_unit IS NOT NULL
       AND lower(trim(COALESCE(v_unit, ''))) IS DISTINCT FROM lower(trim(p_expected_unit)) THEN
        RETURN jsonb_strip_nulls(jsonb_build_object(
            'ok', false,
            'reason', format('unit mismatch: expected %s, got %s', p_expected_unit, COALESCE(v_unit, 'none')),
            'value', v_value, 'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
    END IF;

    -- (3) statische Plausibilitaet
    IF (p_min IS NOT NULL AND v_value < p_min) OR (p_max IS NOT NULL AND v_value > p_max) THEN
        RETURN jsonb_strip_nulls(jsonb_build_object(
            'ok', false,
            'reason', format('value %s outside plausibility bounds [%s, %s]',
                             v_value, COALESCE(p_min::text, '-'), COALESCE(p_max::text, '-')),
            'value', v_value, 'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
    END IF;

    -- (4) Kontinuitaet (Jump-Guard)
    IF p_jump_pct IS NOT NULL AND p_last IS NOT NULL AND p_last <> 0
       AND abs(v_value - p_last) / abs(p_last) * 100 > p_jump_pct THEN
        RETURN jsonb_strip_nulls(jsonb_build_object(
            'ok', false,
            'reason', format('implausible jump: %s -> %s exceeds max_jump_pct %s%%',
                             p_last, v_value, p_jump_pct),
            'value', v_value, 'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
    END IF;

    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ok', true, 'value', v_value, 'unit', v_unit, 'as_of', v_as_of, 'source_url', v_src));
END;
$$;
