-- ============================================================
-- core.fn_plan_sync (ATOMIC WRITE — Erinnerungen eines Plans abgleichen)
--   Legt Termin-Waechter eines Plans an, verschiebt und schaltet sie ab; gerufen aus agent.fn_advisor_publish_plan (mit plan_id,
--   zaehlt zur Publish-Transaktion) und aus agent.tool_sync_plan (aktiver Plan, keine neue Version). Trigger-Regeln bleiben allein
--   in agent.fn_create_monitor_trigger / agent.fn_set_monitor_trigger. Erst alles pruefen, dann schreiben.
--   Regel je Termin (erste zutreffende, Name getrimmt, ohne Gross-/Kleinschreibung): gleiches Datum -> existing;
--   anderes Datum -> verschoben (fired wird scharf); vom Nutzer abgeschaltet -> disabled; vom Plan weggeraeumt -> wieder scharf;
--   andere Art -> other_type; gleicher Name in general (ausser E2E) -> exists_general; abgelehnt ohne force -> declined;
--   abgelehnt mit force -> Ablehnung weg, anlegen; sonst anlegen. Vergangenheit nur fuer Neues und Verschobenes.
--   Eingabe jsonb: domain, chat_id, plan_id (nur intern), reminders [{label 1..80, remind_on ISO, action_note? bis 300, deadline?, force?}],
--     declined [{label, remind_on?}], retire [{label}], watch_candidates [Text bis 120, max 10], reminders_checked_on (effective des Probelaufs).
--     Arrays auch als JSON-String, leerer String = nicht angegeben. warn_days_before folgt nur aus deadline und advisor.reminder_deadline_warn_days.
--   Rueckgabe: {ok:true, plan_id, synced_at, created:[{trigger_id,label,due_date}], moved:[...], retired:[{trigger_id,label}], skipped:[{label,reason}],
--     changes, effective:{reminders_checked_on}, card_lines}.
--   Korrigierbar {ok:false, code, reason}: invalid_reminders, invalid_date, duplicate_reminder, sync_conflict, retire_unknown, retire_protected,
--     too_many_reminders, no_active_plan, sync_stale (Rollback, wenn ein Eintrag erst im Write scheitert).
--   SECURITY INVOKER: laeuft unter der Host-Cred, keine Grants an Paket-Rollen. Tests: tests/db/core/test_fn_plan_sync.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_plan_sync(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_domain   text := NULLIF(trim(COALESCE(p->>'domain', '')), '');
    v_e2e      boolean;
    v_pkg      text;
    v_ctx      text;
    v_scope    text;
    v_perm     text;
    v_pid      text;
    v_err      text;
    v_today    date := core.fn_today();
    v_check    date;
    v_warn     int;
    v_args     jsonb := '{}'::jsonb;
    v_key      text;
    v_val      jsonb;
    v_rem      jsonb;
    v_dec      jsonb;
    v_ret      jsonb;
    v_watch    jsonb;
    v_plan_id  int;
    v_i        int;
    v_item     jsonb;
    v_label    text;
    v_due      date;
    v_t        agent.monitor_triggers%ROWTYPE;
    v_declined boolean;
    v_new      jsonb := '[]'::jsonb;
    v_moves    jsonb := '[]'::jsonb;
    v_skipped  jsonb := '[]'::jsonb;
    v_retire   jsonb := '[]'::jsonb;
    v_newdec   jsonb := '[]'::jsonb;
    v_force    text[] := '{}';
    v_created  jsonb := '[]'::jsonb;
    v_moved    jsonb := '[]'::jsonb;
    v_retired  jsonb := '[]'::jsonb;
    v_lines    jsonb := '[]'::jsonb;
    v_r        jsonb;
    v_fail     text;
    v_stamp    timestamptz;
BEGIN
    IF v_domain IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', 'domain is required');
    END IF;
    v_e2e := v_domain ~ '^__e2e_';
    v_pkg := COALESCE((SELECT a.package FROM core.advisors a WHERE a.domain = regexp_replace(v_domain, '^__e2e_(.+)__$', '\1')), 'core');
    v_ctx := COALESCE((SELECT plan_context FROM core.advisors WHERE domain = v_domain), v_domain || '_planning');
    SELECT cs.scope, cs.write_permission INTO v_scope, v_perm FROM core.context_scopes cs WHERE cs.context_name = v_ctx;
    v_scope := COALESCE(v_scope, 'household');
    v_perm  := COALESCE(v_perm, 'owner_only');
    IF v_scope = 'per_user' AND p->>'chat_id' ~ '^[0-9]+$' THEN
        v_pid := agent.fn_resolve_sender((p->>'chat_id')::bigint) ->> 'person_id';
    END IF;
    IF v_scope = 'per_user' AND v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', 'cannot resolve person for per-user plan');
    END IF;
    v_err := agent.fn_check_write_permission(v_perm, p->>'chat_id', v_pid);
    IF v_err IS NOT NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', v_err);
    END IF;

    -- Array oder JSON-String (Tool-Binding liefert Strings); leerer String = nicht angegeben.
    FOREACH v_key IN ARRAY ARRAY['reminders', 'declined', 'retire', 'watch_candidates'] LOOP
        v_val := NULL;
        IF p ? v_key AND jsonb_typeof(p->v_key) IS DISTINCT FROM 'null' AND btrim(COALESCE(p->>v_key, '')) <> '' THEN
            IF jsonb_typeof(p->v_key) = 'string' THEN
                BEGIN
                    v_val := (p->>v_key)::jsonb;
                EXCEPTION WHEN OTHERS THEN
                    RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', v_key || ' is not valid JSON: ' || left(p->>v_key, 120));
                END;
            ELSE
                v_val := p->v_key;
            END IF;
            IF jsonb_typeof(v_val) IS DISTINCT FROM 'array' THEN
                RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', v_key || ' must be a JSON array');
            END IF;
            v_args := v_args || jsonb_build_object(v_key, v_val);
        END IF;
    END LOOP;
    v_rem   := COALESCE(v_args->'reminders', '[]'::jsonb);
    v_dec   := COALESCE(v_args->'declined', '[]'::jsonb);
    v_ret   := COALESCE(v_args->'retire', '[]'::jsonb);
    v_watch := v_args->'watch_candidates';

    IF jsonb_array_length(v_rem) > 30 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'too_many_reminders', 'reason', 'at most 30 reminders per plan sync');
    END IF;
    IF v_watch IS NOT NULL AND (jsonb_array_length(v_watch) > 10
        OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_watch) w
                    WHERE jsonb_typeof(w) <> 'string' OR length(w #>> '{}') NOT BETWEEN 1 AND 120)) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', 'watch_candidates: at most 10 texts of 1-120 characters');
    END IF;

    -- Effective Day: ein Tipp nach Mitternacht darf den auf der Karte gezeigten Tag nicht nachtraeglich ablehnen.
    BEGIN
        v_check := LEAST(COALESCE(NULLIF(p->>'reminders_checked_on', '')::date, v_today), v_today);
    EXCEPTION WHEN OTHERS THEN
        v_check := v_today;
    END;

    v_i := 0;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_rem) LOOP
        v_i := v_i + 1;
        v_label := btrim(COALESCE(v_item->>'label', ''));
        IF jsonb_typeof(v_item) <> 'object' OR length(v_label) NOT BETWEEN 1 AND 80 OR length(COALESCE(v_item->>'action_note', '')) > 300 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders',
                'reason', format('reminder #%s: label must be 1-80 characters, action_note at most 300', v_i));
        END IF;
        IF COALESCE(v_item->>'remind_on', '') !~ '^\d{4}-\d{2}-\d{2}$' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason', format('reminder #%s: remind_on must be an ISO date (YYYY-MM-DD)', v_i));
        END IF;
        BEGIN
            PERFORM (v_item->>'remind_on')::date;
        EXCEPTION WHEN OTHERS THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason', format('reminder #%s: remind_on is not a calendar date', v_i));
        END;
    END LOOP;
    IF (SELECT count(*) <> count(DISTINCT lower(btrim(r->>'label'))) FROM jsonb_array_elements(v_rem) r) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'duplicate_reminder', 'reason', 'the same reminder name appears twice in reminders');
    END IF;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_dec || v_ret) LOOP
        IF jsonb_typeof(v_item) <> 'object' OR length(btrim(COALESCE(v_item->>'label', ''))) NOT BETWEEN 1 AND 80 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_reminders', 'reason', 'declined and retire entries need a label of 1-80 characters');
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_rem) r
                WHERE lower(btrim(r->>'label')) IN (SELECT lower(btrim(x->>'label')) FROM jsonb_array_elements(v_dec || v_ret) x)) THEN
        RETURN jsonb_build_object('ok', false, 'code', 'sync_conflict', 'reason', 'a name appears in reminders and also in declined or retire');
    END IF;

    IF NULLIF(p->>'plan_id', '') IS NOT NULL THEN
        v_plan_id := (p->>'plan_id')::int;
    ELSE
        SELECT id INTO v_plan_id FROM agent.advisor_plans
         WHERE domain = v_domain AND person_id IS NOT DISTINCT FROM v_pid AND status = 'active' FOR UPDATE;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'code', 'no_active_plan', 'reason', 'no published plan exists for domain ' || v_domain);
        END IF;
    END IF;

    v_warn := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'reminder_deadline_warn_days'), '')::int, 7);

    -- Klassifizieren (Reihenfolge = die Regel-Tabelle im Kopf).
    v_i := 0;
    FOR v_item IN SELECT value FROM jsonb_array_elements(v_rem) LOOP
        v_i := v_i + 1;
        v_label := btrim(v_item->>'label');
        v_due := (v_item->>'remind_on')::date;
        SELECT * INTO v_t FROM agent.monitor_triggers t WHERE t.domain = v_domain AND lower(btrim(t.label)) = lower(v_label) LIMIT 1;
        IF FOUND THEN
            IF v_t.status = 'disabled' AND v_t.retired_by_plan_at IS NULL THEN
                v_skipped := v_skipped || jsonb_build_object('label', v_label, 'reason', 'disabled');
                CONTINUE;
            ELSIF v_t.trigger_type <> 'date' THEN
                v_skipped := v_skipped || jsonb_build_object('label', v_label, 'reason', 'other_type');
                CONTINUE;
            ELSIF v_t.status <> 'disabled' AND v_t.due_date = v_due THEN
                v_skipped := v_skipped || jsonb_build_object('label', v_label, 'reason', 'existing');
                CONTINUE;
            END IF;
            IF v_due < v_check THEN
                RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason', format('reminder #%s: the date is in the past', v_i));
            END IF;
            v_moves := v_moves || jsonb_build_object('label', v_t.label, 'due', GREATEST(v_due, v_today),
                'warn', CASE WHEN (v_item->>'deadline') = 'true' THEN v_warn ELSE 0 END, 'note', v_item->>'action_note');
            CONTINUE;
        END IF;
        IF NOT v_e2e AND EXISTS (SELECT 1 FROM agent.monitor_triggers t WHERE t.domain = 'general' AND lower(btrim(t.label)) = lower(v_label)) THEN
            v_skipped := v_skipped || jsonb_build_object('label', v_label, 'reason', 'exists_general');
            CONTINUE;
        END IF;
        v_declined := EXISTS (SELECT 1 FROM agent.plan_reminder_declines d
                               WHERE d.domain = v_domain AND d.person_id IS NOT DISTINCT FROM v_pid AND lower(btrim(d.label)) = lower(v_label));
        IF v_declined AND COALESCE((v_item->>'force') = 'true', false) IS NOT TRUE THEN
            v_skipped := v_skipped || jsonb_build_object('label', v_label, 'reason', 'declined');
            CONTINUE;
        END IF;
        IF v_due < v_check THEN
            RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason', format('reminder #%s: the date is in the past', v_i));
        END IF;
        IF v_declined THEN v_force := v_force || lower(v_label); END IF;
        v_new := v_new || jsonb_build_object('label', v_label, 'due', GREATEST(v_due, v_today),
            'warn', CASE WHEN (v_item->>'deadline') = 'true' THEN v_warn ELSE 0 END, 'note', v_item->>'action_note');
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(v_ret) LOOP
        v_label := btrim(v_item->>'label');
        SELECT * INTO v_t FROM agent.monitor_triggers t WHERE t.domain = v_domain AND lower(btrim(t.label)) = lower(v_label) LIMIT 1;
        IF NOT FOUND THEN
            RETURN jsonb_build_object('ok', false, 'code', 'retire_unknown', 'reason', format('no reminder named "%s" in this plan', v_label));
        ELSIF v_t.origin = 'core' THEN
            RETURN jsonb_build_object('ok', false, 'code', 'retire_protected', 'reason', format('"%s" is a system reminder and cannot be retired', v_label));
        ELSIF v_t.status <> 'disabled' THEN
            v_retire := v_retire || jsonb_build_object('id', v_t.id, 'label', v_t.label);
        END IF;
    END LOOP;

    FOR v_item IN SELECT value FROM jsonb_array_elements(v_dec) LOOP
        v_label := btrim(v_item->>'label');
        IF NOT EXISTS (SELECT 1 FROM agent.plan_reminder_declines d
                        WHERE d.domain = v_domain AND d.person_id IS NOT DISTINCT FROM v_pid AND lower(btrim(d.label)) = lower(v_label)) THEN
            IF NULLIF(v_item->>'remind_on', '') IS NOT NULL AND (v_item->>'remind_on') !~ '^\d{4}-\d{2}-\d{2}$' THEN
                RETURN jsonb_build_object('ok', false, 'code', 'invalid_date', 'reason', format('declined "%s": remind_on must be an ISO date', v_label));
            END IF;
            v_newdec := v_newdec || jsonb_build_object('label', v_label, 'remind_on', NULLIF(v_item->>'remind_on', ''));
        END IF;
    END LOOP;

    -- Schreib-Schleife im Savepoint: ein ok:false der Trigger-fns (Bestand zwischen Karte und Tipp geaendert) rollt alles zurueck.
    BEGIN
        DELETE FROM agent.plan_reminder_declines d
         WHERE d.domain = v_domain AND d.person_id IS NOT DISTINCT FROM v_pid AND lower(btrim(d.label)) = ANY (v_force);

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_new) LOOP
            v_r := agent.fn_create_monitor_trigger(jsonb_build_object(
                'domain', v_domain, 'package', v_pkg, 'label', v_item->>'label', 'trigger_type', 'date', 'acquisition_method', 'none',
                'due_date', v_item->>'due', 'warn_days_before', v_item->>'warn', 'check_interval', '1 day', 'action_note', v_item->>'note'));
            IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN v_fail := v_r->>'reason'; RAISE EXCEPTION USING ERRCODE = 'LA002'; END IF;
            v_created := v_created || jsonb_build_object('trigger_id', (v_r->>'trigger_id')::int, 'label', v_item->>'label', 'due_date', v_item->>'due');
            v_lines := v_lines || jsonb_build_object('label', 'core.hitl.plan_sync_new', 'kind', 'tpl', 'value', 'core.tpl.plan_sync_item',
                'params', jsonb_build_object('date', core.fn_ui_date((v_item->>'due')::date), 'name', v_item->>'label'));
        END LOOP;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_moves) LOOP
            -- check_interval mitsenden: setzt next_check_at auf jetzt, auch wenn der Waechter disabled -> armed wechselt.
            v_r := agent.fn_set_monitor_trigger(jsonb_build_object(
                'domain', v_domain, 'label', v_item->>'label', 'due_date', v_item->>'due', 'status', 'armed', 'check_interval', '1 day',
                'warn_days_before', v_item->>'warn', 'action_note', v_item->>'note'));
            IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN v_fail := v_r->>'reason'; RAISE EXCEPTION USING ERRCODE = 'LA002'; END IF;
            v_moved := v_moved || jsonb_build_object('trigger_id', (v_r->>'trigger_id')::int, 'label', v_item->>'label', 'due_date', v_item->>'due');
            v_lines := v_lines || jsonb_build_object('label', 'core.hitl.plan_sync_moved', 'kind', 'tpl', 'value', 'core.tpl.plan_sync_item',
                'params', jsonb_build_object('date', core.fn_ui_date((v_item->>'due')::date), 'name', v_item->>'label'));
        END LOOP;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_retire) LOOP
            v_r := agent.fn_set_monitor_trigger(jsonb_build_object('domain', v_domain, 'label', v_item->>'label', 'status', 'disabled'));
            IF NOT COALESCE((v_r->>'ok')::boolean, false) THEN v_fail := v_r->>'reason'; RAISE EXCEPTION USING ERRCODE = 'LA002'; END IF;
            UPDATE agent.monitor_triggers SET retired_by_plan_at = now() WHERE id = (v_item->>'id')::int;
            v_retired := v_retired || jsonb_build_object('trigger_id', (v_item->>'id')::int, 'label', v_item->>'label');
            v_lines := v_lines || jsonb_build_object('label', 'core.hitl.plan_sync_retired', 'kind', 'text', 'value', v_item->>'label');
        END LOOP;

        FOR v_item IN SELECT value FROM jsonb_array_elements(v_newdec) LOOP
            INSERT INTO agent.plan_reminder_declines (domain, package, person_id, label, remind_on)
            VALUES (v_domain, v_pkg, v_pid, v_item->>'label', NULLIF(v_item->>'remind_on', '')::date);
            v_lines := v_lines || jsonb_build_object('label', 'core.hitl.plan_sync_declined', 'kind', 'text', 'value', v_item->>'label');
        END LOOP;

        UPDATE agent.advisor_plans
           SET synced_at = now(), watch_candidates = COALESCE(v_watch, watch_candidates)
         WHERE id = v_plan_id
         RETURNING synced_at INTO v_stamp;
    EXCEPTION WHEN SQLSTATE 'LA002' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'sync_stale',
            'reason', 'a reminder changed since the preview, nothing was saved: ' || COALESCE(v_fail, 'unknown'));
    END;

    RETURN jsonb_build_object('ok', true, 'plan_id', v_plan_id, 'synced_at', v_stamp::text,
        'created', v_created, 'moved', v_moved, 'retired', v_retired, 'skipped', v_skipped,
        'changes', jsonb_array_length(v_created) + jsonb_array_length(v_moved) + jsonb_array_length(v_retired) + jsonb_array_length(v_newdec),
        'effective', jsonb_build_object('reminders_checked_on', v_check::text),
        'card_lines', v_lines);
END;
$$;
