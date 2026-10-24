-- ============================================================
-- fn_create_monitor_trigger (ATOMIC WRITE — Monitor-Trigger anlegen)
--   Aufgerufen vom HITL-gegateten Tool agent.tool_create_monitor_trigger (Monitor-Agent:
--   domain vom LLM aus bekanntem Set; Advisor-Binding: domain FIX 'finance').
--   ALLE DB-CHECKs sind hier als freundliche {ok:false}-Guards gespiegelt (kein RAISE
--   -> kein Owner-Alert; der Agent reicht reason an den Nutzer). Dublette via
--   unique_violation-Catch (UNIQUE(domain, lower(label)) ist das Gesetz).
--   probe_observation (optional): die VOR dem Gate per fn_monitor_probe validierte
--   Test-Beschaffung — wird nach Approve als erste Observation geloggt und seedet
--   last_value (+ reference_value-Ratchet bei drawdown). So startet kein Trigger
--   mit ungetesteter Beschaffung.
--   Beschaffungs-Methode (Phase B): Core-Builtins web_search | sql | none direkt; jede andere Methode MUSS
--     eine VERFUEGBARE Paket-Methode aus core.monitor_acquisition_methods sein (agent.fn_monitor_method_status) —
--     ihre acquisition_params prueft + normalisiert die validate_fn des Pakets (fn_monitor_validate_params).
--   Eingabe jsonb: domain (default 'general'), label, trigger_type, acquisition_method
--     (default none), acquisition_prompt | acquisition_sql | acquisition_params (Paket-Methode, Objekt),
--     comparator, threshold_value, drawdown_pct, reference_value (expliziter Seed),
--     due_date, warn_days_before, expected_unit, min_plausible, max_plausible,
--     max_jump_pct, check_interval (Text, z. B. '1 day'), action_note, probe_observation.
--   RUECKGABE (Post-State): {ok:true, trigger_id, status:'armed', next_check_at,
--     check_interval (normalisiert — DB-berechnet), armed_count (Domain)}.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_create_monitor_trigger(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain   TEXT := COALESCE(NULLIF(trim(p->>'domain'), ''), 'general');
    v_pkg      TEXT := lower(trim(COALESCE(p->>'package', 'core')));  -- Lifecycle-Owner (Binding-fix, NIE $fromAI); Default core = Host
    v_label    TEXT := trim(COALESCE(p->>'label', ''));
    v_type     TEXT := NULLIF(trim(COALESCE(p->>'trigger_type', '')), '');
    v_method   TEXT := COALESCE(NULLIF(trim(p->>'acquisition_method'), ''), 'none');
    v_interval INTERVAL;
    v_spec     JSONB := '{}'::jsonb;
    v_prompt   TEXT;
    v_sql      TEXT;
    v_mst      JSONB;
    v_val      JSONB;
    v_unit     TEXT := NULLIF(trim(COALESCE(p->>'expected_unit', '')), '');
    v_min      NUMERIC := NULLIF(p->>'min_plausible', '')::numeric;
    v_max      NUMERIC := NULLIF(p->>'max_plausible', '')::numeric;
    v_jump     NUMERIC := NULLIF(p->>'max_jump_pct', '')::numeric;
    v_cmp      TEXT := NULLIF(trim(COALESCE(p->>'comparator', '')), '');
    v_thr      NUMERIC := NULLIF(p->>'threshold_value', '')::numeric;
    v_dd       NUMERIC := NULLIF(p->>'drawdown_pct', '')::numeric;
    v_ref      NUMERIC := NULLIF(p->>'reference_value', '')::numeric;
    v_due      DATE;
    v_warn     INT := COALESCE(NULLIF(p->>'warn_days_before', '')::int, 0);
    v_probe    JSONB := p->'probe_observation';
    v_probe_val NUMERIC;
    v_id       INT;
    v_next     TIMESTAMPTZ;
    v_norm_int TEXT;
    v_armed    INT;
BEGIN
    -- Basis-Guards
    IF v_label = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'label must be non-empty');
    END IF;
    IF v_type IS NULL OR v_type NOT IN ('threshold', 'drawdown', 'date', 'recurring_info') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'trigger_type must be one of threshold|drawdown|date|recurring_info, got ' || COALESCE(v_type, 'none'));
    END IF;
    v_mst := agent.fn_monitor_method_status(v_method);
    IF NOT COALESCE((v_mst->>'available')::boolean, false) THEN
        RETURN jsonb_build_object('ok', false,
            'reason', (v_mst->>'reason') || ' — use web_search|sql|none or an available package method');
    END IF;
    -- package = Lifecycle-Owner (Format-Guard spiegelt monitor_triggers_package_chk; CHECK = Backstop)
    IF v_pkg !~ '^[a-z0-9_]+$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'invalid package (expect ^[a-z0-9_]+$): ' || v_pkg);
    END IF;

    -- check_interval parsen (Roh-Wert vom Nutzer, die DB normalisiert)
    BEGIN
        v_interval := (p->>'check_interval')::interval;
    EXCEPTION WHEN OTHERS THEN
        v_interval := NULL;
    END;
    IF v_interval IS NULL OR v_interval <= INTERVAL '0' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'check_interval is not a valid positive interval (e.g. ''12 hours'', ''1 day'', ''2 weeks''), got ' || COALESCE(p->>'check_interval', 'none'));
    END IF;

    -- Beschaffungs-Spec je Methode validieren + bauen
    IF v_method = 'web_search' THEN
        v_prompt := trim(COALESCE(p->>'acquisition_prompt', ''));
        IF v_prompt = '' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'acquisition_prompt is required for web_search');
        END IF;
        IF v_unit IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'expected_unit is required for web_search (unit-echo validation against internet data)');
        END IF;
        IF v_interval < INTERVAL '12 hours' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'web_search cadence must be at least 12 hours (max 2 checks per day per trigger — free-tier protection)');
        END IF;
        v_spec := jsonb_build_object('prompt', v_prompt);
    ELSIF v_method = 'sql' THEN
        v_sql := regexp_replace(trim(COALESCE(p->>'acquisition_sql', '')), ';\s*$', '');
        IF v_sql = '' OR v_sql !~* '^\s*select\y' OR position(';' in v_sql) > 0 OR length(v_sql) > 2000 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'acquisition_sql rejected: must be a single SELECT statement returning one numeric value (no semicolons, max 2000 chars)');
        END IF;
        v_spec := jsonb_build_object('query', v_sql);
    ELSIF v_method <> 'none' THEN
        -- Paket-Methode: validate_fn des Pakets prueft + normalisiert die Methoden-Parameter
        v_val := agent.fn_monitor_validate_params(v_method, p->'acquisition_params');
        IF NOT COALESCE((v_val->>'ok')::boolean, false) THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_val->>'reason');
        END IF;
        v_spec := v_val->'spec';
    END IF;

    -- Typ x Feld-Konsistenz (spiegelt monitor_triggers_type_consistency)
    IF v_type = 'threshold' THEN
        IF v_cmp IS NULL OR v_cmp NOT IN ('gte', 'lte') OR v_thr IS NULL THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'threshold triggers require comparator (gte|lte) and threshold_value');
        END IF;
        IF v_method = 'none' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'threshold triggers need a value acquisition (web_search|sql|a package method)');
        END IF;
        v_due := NULL; v_dd := NULL;
    ELSIF v_type = 'drawdown' THEN
        IF v_dd IS NULL OR v_dd <= 0 OR v_dd >= 100 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'drawdown triggers require drawdown_pct between 0 and 100 (exclusive), got ' || COALESCE(v_dd::text, 'none'));
        END IF;
        IF v_method = 'none' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'drawdown triggers need a value acquisition (web_search|sql|a package method)');
        END IF;
        v_due := NULL; v_cmp := NULL; v_thr := NULL;
    ELSIF v_type = 'date' THEN
        BEGIN
            v_due := (p->>'due_date')::date;
        EXCEPTION WHEN OTHERS THEN
            v_due := NULL;
        END;
        IF v_due IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'date triggers require a valid due_date (YYYY-MM-DD)');
        END IF;
        IF v_method <> 'none' THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'date triggers are acquisition-free (acquisition_method must be none)');
        END IF;
        v_cmp := NULL; v_thr := NULL; v_dd := NULL;
    ELSE  -- recurring_info
        v_due := NULL; v_cmp := NULL; v_thr := NULL; v_dd := NULL;
    END IF;

    -- Plausibilitaets-Konfiguration
    IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min >= v_max THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('min_plausible (%s) must be below max_plausible (%s)', v_min, v_max));
    END IF;
    IF v_jump IS NOT NULL AND v_jump <= 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'max_jump_pct must be positive');
    END IF;
    IF v_warn < 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'warn_days_before must be >= 0');
    END IF;

    -- INSERT (unique_violation = Dubletten-Gesetz; check_violation = Backstop)
    BEGIN
        INSERT INTO agent.monitor_triggers
            (domain, package, label, trigger_type, acquisition_method, acquisition_spec,
             comparator, threshold_value, drawdown_pct, reference_value,
             due_date, warn_days_before, expected_unit,
             min_plausible, max_plausible, max_jump_pct,
             check_interval, action_note)
        VALUES
            (v_domain, v_pkg, v_label, v_type, v_method, v_spec,
             v_cmp, v_thr, v_dd, CASE WHEN v_type = 'drawdown' THEN v_ref END,
             v_due, v_warn, v_unit,
             v_min, v_max, v_jump,
             v_interval, NULLIF(trim(COALESCE(p->>'action_note', '')), ''))
        RETURNING id, next_check_at, check_interval::text
        INTO v_id, v_next, v_norm_int;
    EXCEPTION
        WHEN unique_violation THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('a trigger labeled "%s" already exists in domain %s — use tool_set_monitor_trigger to change it', v_label, v_domain));
        WHEN check_violation THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'constraint violation: ' || SQLERRM);
    END;

    -- Probe-Seed: validierte Test-Beschaffung als erste Observation + last_value/Ratchet
    IF v_probe IS NOT NULL AND jsonb_typeof(v_probe) = 'object'
       AND COALESCE((v_probe->>'ok')::boolean, false) THEN
        BEGIN
            v_probe_val := (v_probe->>'value')::numeric;
        EXCEPTION WHEN OTHERS THEN
            v_probe_val := NULL;
        END;
        IF v_probe_val IS NOT NULL THEN
            INSERT INTO agent.monitor_observations
                (trigger_id, ok, value, unit, as_of, source_url, reason)
            VALUES (v_id, true, v_probe_val, v_probe->>'unit', v_probe->>'as_of',
                    COALESCE(v_probe->>'source_url', 'probe'), 'probe before HITL approval');
            UPDATE agent.monitor_triggers
               SET last_value       = v_probe_val,
                   last_value_as_of = v_probe->>'as_of',
                   reference_value  = CASE WHEN trigger_type = 'drawdown'
                                           THEN COALESCE(v_ref, v_probe_val)
                                           ELSE reference_value END
             WHERE id = v_id;
        END IF;
    END IF;

    SELECT COUNT(*) INTO v_armed FROM agent.monitor_triggers t
     WHERE t.domain = v_domain AND t.status = 'armed';

    RETURN jsonb_build_object(
        'ok', true,
        'trigger_id', v_id,
        'status', 'armed',
        'next_check_at', v_next::text,
        'check_interval', v_norm_int,
        'armed_count', v_armed);
END;
$$;
