-- ============================================================
-- fn_set_monitor_trigger (ATOMIC WRITE — Monitor-Trigger aendern, Lifecycle inkl.)
--   Aufgerufen vom HITL-gegateten Tool agent.tool_set_monitor_trigger (nur Monitor-Agent).
--   Partielles UPDATE via COALESCE(NULLIF) — "nicht gesendet = unveraendert". Aufloesung
--   per (domain, label) ueber fn_resolve_monitor_trigger (0/>1 -> {ok:false} + Kandidaten).
--   Lifecycle:
--     * status='armed' auf einem fired Trigger = RE-ARM (bewusster Akt): fired_at und
--       fail_streak werden geloescht, next_check_at = now (neue Epoche)
--     * status='disabled' = parken (Due-Selection ueberspringt)
--     * reset_peak=true = Drawdown-Ratchet nullen (neue Referenz-Epoche; naechste
--       saubere Beobachtung seedet neu)
--   Typ-Wechsel ist ABGELEHNT (delete + create — die Feld-Konsistenz haengt am Typ).
--   Spec-Edits (Prompt/SQL/Methoden-Parameter) werden re-validiert (Repair-Flow: Quellen driften);
--   Paket-Methode (Phase B): acquisition_params (Objekt) wird ueber die bestehende Spec gemergt (nur gesendete
--   Keys aendern sich) und von der validate_fn des Pakets geprueft/normalisiert (fn_monitor_validate_params);
--   ohne acquisition_params bleibt die Spec unberuehrt -> Disable/Re-Arm/Label gehen IMMER, auch wenn das Paket
--   der Methode gerade fehlt ("always silenceable").
--   Cadence-Aenderung re-anker next_check_at = now; Web-Rate-Limit (>= 12h) gespiegelt.
--   due_date: YYYY-MM-DD oder relativ ("+6 months") -> core.fn_resolve_date; ein neu gesendetes Datum in der
--     Vergangenheit -> {ok:false}.
--   RUECKGABE (Post-State): {ok:true, trigger_id, status, next_check_at,
--     check_interval, due_date, reference_value}.
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_monitor_trigger(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain  TEXT := COALESCE(NULLIF(trim(p->>'domain'), ''), 'general');
    v_r       RECORD;
    v_t       agent.monitor_triggers%ROWTYPE;
    v_new_label TEXT := NULLIF(trim(COALESCE(p->>'new_label', '')), '');
    v_status  TEXT := NULLIF(trim(COALESCE(p->>'status', '')), '');
    v_interval INTERVAL;
    v_interval_given BOOLEAN := false;
    v_spec    JSONB;
    v_sql     TEXT;
    v_params  JSONB := p->'acquisition_params';
    v_val     JSONB;
    v_rearm   BOOLEAN := false;
    v_due     DATE;
    v_avail   JSONB;
BEGIN
    -- Aufloesung (auch fired/disabled — Lifecycle braucht sie)
    SELECT * INTO v_r FROM agent.fn_resolve_monitor_trigger(p->>'label', v_domain, FALSE);
    IF v_r.hit_count = 0 THEN
        SELECT COALESCE(jsonb_agg(t.label ORDER BY t.label), '[]'::jsonb) INTO v_avail
        FROM agent.monitor_triggers t WHERE t.domain = v_domain;
        RETURN jsonb_build_object('ok', false,
            'reason', format('no trigger labeled "%s" in domain %s', COALESCE(p->>'label', ''), v_domain),
            'available_labels', v_avail);
    ELSIF v_r.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'label is ambiguous — specify the domain',
            'candidates', v_r.candidates);
    END IF;

    SELECT * INTO v_t FROM agent.monitor_triggers WHERE id = v_r.id FOR UPDATE;

    -- Typ-Wechsel abgelehnt
    IF NULLIF(trim(COALESCE(p->>'trigger_type', '')), '') IS NOT NULL
       AND p->>'trigger_type' IS DISTINCT FROM v_t.trigger_type THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('trigger type cannot be changed (%s -> %s) — delete and create a new trigger',
                             v_t.trigger_type, p->>'trigger_type'));
    END IF;

    -- Status-Eingabe validieren (fired ist nie setzbar — das macht nur fn_monitor_evaluate)
    IF v_status IS NOT NULL AND v_status NOT IN ('armed', 'disabled') THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'status must be armed (re-arm) or disabled — fired is set only by the monitor itself');
    END IF;
    v_rearm := (v_status = 'armed' AND v_t.status = 'fired');

    -- check_interval (optional)
    IF NULLIF(trim(COALESCE(p->>'check_interval', '')), '') IS NOT NULL THEN
        BEGIN
            v_interval := (p->>'check_interval')::interval;
        EXCEPTION WHEN OTHERS THEN
            v_interval := NULL;
        END;
        IF v_interval IS NULL OR v_interval <= INTERVAL '0' THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'check_interval is not a valid positive interval, got ' || (p->>'check_interval'));
        END IF;
        v_interval_given := true;
    ELSE
        v_interval := v_t.check_interval;
    END IF;
    IF v_t.acquisition_method = 'web_search' AND v_interval < INTERVAL '12 hours' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'web_search cadence must be at least 12 hours (max 2 checks per day per trigger)');
    END IF;

    -- Spec-Edits innerhalb der bestehenden Methode (Repair-Flow)
    v_spec := v_t.acquisition_spec;
    IF v_t.acquisition_method = 'web_search'
       AND NULLIF(trim(COALESCE(p->>'acquisition_prompt', '')), '') IS NOT NULL THEN
        v_spec := jsonb_build_object('prompt', trim(p->>'acquisition_prompt'));
    ELSIF v_t.acquisition_method = 'sql'
       AND NULLIF(trim(COALESCE(p->>'acquisition_sql', '')), '') IS NOT NULL THEN
        v_sql := regexp_replace(trim(p->>'acquisition_sql'), ';\s*$', '');
        IF v_sql !~* '^\s*select\y' OR position(';' in v_sql) > 0 OR length(v_sql) > 2000 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'acquisition_sql rejected: must be a single SELECT statement (no semicolons, max 2000 chars)');
        END IF;
        v_spec := jsonb_build_object('query', v_sql);
    ELSIF v_t.acquisition_method NOT IN ('web_search', 'sql', 'none')
          AND v_params IS NOT NULL AND jsonb_typeof(v_params) <> 'null'
          AND v_params NOT IN ('""'::jsonb, '{}'::jsonb) THEN
        -- Nicht-Objekt (z. B. der Build-Sentinel '__invalid_json__') -> fn_monitor_validate_params lehnt ab.
        v_val := agent.fn_monitor_validate_params(v_t.acquisition_method,
                     CASE WHEN jsonb_typeof(v_params) = 'object' THEN v_t.acquisition_spec || v_params ELSE v_params END);
        IF NOT COALESCE((v_val->>'ok')::boolean, false) THEN
            RETURN jsonb_build_object('ok', false, 'reason', v_val->>'reason');
        END IF;
        v_spec := v_val->'spec';
    END IF;

    -- due_date (nur date-Typ sinnvoll; sonst ignoriert die Typ-CHECK den Wert ohnehin)
    -- WP3: relative Angabe ("+6 months") rechnet die DB; Vergangenheits-Check nur fuer ein neu gesendetes Datum.
    IF NULLIF(trim(COALESCE(p->>'due_date', '')), '') IS NOT NULL THEN
        v_due := core.fn_resolve_date(p->>'due_date');
        IF v_due IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason',
                'due_date must be YYYY-MM-DD or relative to today (e.g. +6 months, in 3 weeks)');
        END IF;
        IF v_due < core.fn_today() THEN
            RETURN jsonb_build_object('ok', false, 'reason', format('due_date %s is in the past', v_due));
        END IF;
    END IF;

    BEGIN
        UPDATE agent.monitor_triggers SET
            label            = COALESCE(v_new_label, label),
            acquisition_spec = v_spec,
            comparator       = CASE WHEN NULLIF(trim(COALESCE(p->>'comparator','')),'') IN ('gte','lte')
                                    THEN p->>'comparator' ELSE comparator END,
            threshold_value  = COALESCE(NULLIF(p->>'threshold_value', '')::numeric, threshold_value),
            drawdown_pct     = COALESCE(NULLIF(p->>'drawdown_pct', '')::numeric, drawdown_pct),
            due_date         = COALESCE(v_due, due_date),
            warn_days_before = COALESCE(NULLIF(p->>'warn_days_before', '')::int, warn_days_before),
            expected_unit    = COALESCE(NULLIF(trim(COALESCE(p->>'expected_unit','')), ''), expected_unit),
            min_plausible    = COALESCE(NULLIF(p->>'min_plausible', '')::numeric, min_plausible),
            max_plausible    = COALESCE(NULLIF(p->>'max_plausible', '')::numeric, max_plausible),
            max_jump_pct     = COALESCE(NULLIF(p->>'max_jump_pct', '')::numeric, max_jump_pct),
            action_note      = COALESCE(NULLIF(trim(COALESCE(p->>'action_note','')), ''), action_note),
            check_interval   = v_interval,
            next_check_at    = CASE WHEN v_rearm OR v_interval_given THEN NOW() ELSE next_check_at END,
            status           = COALESCE(v_status, status),
            fired_at         = CASE WHEN v_rearm THEN NULL ELSE fired_at END,
            fail_streak      = CASE WHEN v_rearm THEN 0 ELSE fail_streak END,
            reference_value  = CASE WHEN COALESCE(NULLIF(trim(COALESCE(p->>'reset_peak', '')), '')::boolean, false)
                                    THEN NULL ELSE reference_value END
        WHERE id = v_r.id;
    EXCEPTION
        WHEN unique_violation THEN
            RETURN jsonb_build_object('ok', false,
                'reason', format('a trigger labeled "%s" already exists in domain %s', v_new_label, v_domain));
        WHEN check_violation THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'constraint violation: ' || SQLERRM);
    END;

    SELECT * INTO v_t FROM agent.monitor_triggers WHERE id = v_r.id;
    RETURN jsonb_build_object(
        'ok', true,
        'trigger_id', v_t.id,
        'status', v_t.status,
        'next_check_at', v_t.next_check_at::text,
        'check_interval', v_t.check_interval::text,
        'due_date', v_t.due_date,
        'reference_value', v_t.reference_value);
END;
$$;
