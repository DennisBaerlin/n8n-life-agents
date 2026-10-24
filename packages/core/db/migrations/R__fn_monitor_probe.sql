-- ============================================================
-- fn_monitor_probe (READ-ONLY — Test-Abruf VOR dem HITL-Gate der Trigger-Tools)
--   Fuehrt die Wert-Beschaffung EXAKT wie der Cron aus und validiert mit derselben
--   Kaskade — der Nutzer bestaetigt im Gate nie eine ungetestete Beschaffung
--   ("Test-Abruf: 4.188,50 USD/oz ..." steht in der Approval-Summary). KEIN Write:
--   die Observation wird erst NACH Approve von fn_create_monitor_trigger geloggt
--   (probe_observation-Parameter).
--     * sql/none: Beschaffung via fn_monitor_acquire (sql unter core_ro)
--     * web_search: der Tool-Workflow beschafft per Claude-web_search-HTTP-Node und reicht
--       die geparste Observation als p.observation herein
--     * Paket-Methode (Phase B): acquisition_params -> fn_monitor_validate_params (validate_fn des Pakets,
--       normalisiert die Spec + liefert die Bestaetigungs-Zeile display) -> fn_monitor_acquire(spec);
--       ungueltige/nicht verfuegbare Methode -> {ok:false, reason}
--   Eingabe jsonb: acquisition_method, acquisition_sql | acquisition_params (Paket-Methode, Objekt) |
--     observation (web), expected_unit, min_plausible, max_plausible, max_jump_pct + last_value
--     (nur set-Pfad), as_of (Test-Injektion).
--   Rueckgabe: normalisierte Observation {ok, value?, unit?, as_of?, source_url?, reason?, display?}
--     (display = tpl-Objekt {kind:'tpl', value, params} oder String; das HITL-Gate rendert beides)
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_probe(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_method  TEXT := COALESCE(NULLIF(trim(p->>'acquisition_method'), ''), 'none');
    v_as_of   DATE := COALESCE(NULLIF(p->>'as_of', '')::date, CURRENT_DATE);
    v_obs     JSONB;
    v_val     JSONB;
    v_display JSONB;
BEGIN
    IF v_method = 'web_search' THEN
        v_obs := p->'observation';
        IF v_obs IS NULL OR jsonb_typeof(v_obs) IS DISTINCT FROM 'object' THEN
            v_obs := jsonb_build_object('ok', false,
                'reason', 'no observation delivered for web_search probe');
        END IF;
    ELSIF v_method = 'sql' THEN
        v_obs := agent.fn_monitor_acquire('sql',
            jsonb_build_object('query', COALESCE(p->>'acquisition_sql', '')), v_as_of);
    ELSIF v_method = 'none' THEN
        v_obs := agent.fn_monitor_acquire('none', '{}'::jsonb, v_as_of);
    ELSE
        v_val := agent.fn_monitor_validate_params(v_method, p->'acquisition_params');
        IF COALESCE((v_val->>'ok')::boolean, false) THEN
            -- display: typisierter Text-Verweis (tpl, Textkatalog Phase C) oder - aeltere Pakete - ein fertiger String
            v_display := CASE WHEN jsonb_typeof(v_val->'display') = 'object' THEN v_val->'display'
                              WHEN NULLIF(v_val->>'display', '') IS NOT NULL THEN v_val->'display' END;
            v_obs := agent.fn_monitor_acquire(v_method, v_val->'spec', v_as_of);
        ELSE
            v_obs := jsonb_build_object('ok', false, 'reason', v_val->>'reason');
        END IF;
    END IF;

    v_obs := agent.fn_validate_observation(
        v_obs, v_method,
        NULLIF(trim(COALESCE(p->>'expected_unit', '')), ''),
        NULLIF(p->>'min_plausible', '')::numeric,
        NULLIF(p->>'max_plausible', '')::numeric,
        NULLIF(p->>'max_jump_pct', '')::numeric,
        NULLIF(p->>'last_value', '')::numeric);
    IF v_display IS NOT NULL THEN
        v_obs := v_obs || jsonb_build_object('display', v_display);   -- Objekt oder String unveraendert
    END IF;
    RETURN v_obs;
END;
$$;
