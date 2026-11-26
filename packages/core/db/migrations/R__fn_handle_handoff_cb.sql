-- ============================================================
-- core.fn_handle_handoff_cb(p) — Registry-Handler des Callback-Prefix 'handoff' (member_permeable)
--   Der Knopf [Durchgehen] der Uebersicht vereinbarter Plan-Aufgaben (handoff:<domain>:<max_task_id>, gesendet von
--   agent.tool_send_handoff_overview). p: { data, chat_id (from.id), chat_type }.
--   Regeln:
--     * nur Privatchat (der Buchhalter-Lauf antwortet in diesem Chat);
--     * <domain> = Zeile aus core.fn_advisor_plan_status des Tippenden (Plan-Domain, Paket aktiv), nie Caller-Text als
--       Identifier; can_write=false (Mitglied) -> Toast "pflegt der Owner";
--     * beansprucht atomar (UPDATE ... RETURNING) die Aufgaben DIESER Person und Domain mit id <= max_task_id, die open
--       sind oder deren working-Claim aelter als advisor.handoff_claim_ttl_minutes ist (Default 120): open -> working,
--       claimed_at = now(). Ein Doppeltipp findet nichts mehr -> Toast "nichts mehr offen".
--     * handoff:<domain>:<max_task_id>:fix = Knopf des Korrektur-Schritts (core.fn_plan_rollout_next, step fix): beansprucht
--       die Zeilen des Ersatzweg-Registers (core.fn_handoff_register) mit possible_now und task_id <= max: deferred -> working
--       (blocked_code weg); eine abgeschlossene Aufgabe wird nie wieder geoeffnet, sondern bekommt eine neue Aufgabe working
--       mit follows_task_id und wanted = der Aufruf der Vorpruefung (UNIQUE auf follows_task_id: hoechstens eine Korrektur).
--   Erfolg {ok:true, route:'handoff', domain, task_ids:[...], tasks:[{id, kind, payload, text, why, wanted, rest}]} -> der Orchestrator
--   ('Handoff route?') startet den handoff_agent der Domain mit festem Auftrag; Dispatch-Fehler -> der Orchestrator gibt
--   die Claims mit core.fn_release_handoff_tasks frei. Sonst {ok:false, reason, toast}. Nie RAISE (Dispatcher-Vertrag).
--   VOLATILE (Claim), SECURITY INVOKER unter der Host-Cred des Dispatchers. Toasts in der Sprache des Tippenden.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/core/test_fn_handoff_register.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handle_handoff_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data   text := COALESCE(p->>'data', '');
    v_domain text := split_part(v_data, ':', 2);
    v_max    text := split_part(v_data, ':', 3);
    v_fix    boolean := v_data LIKE '%:fix';
    v_ids    int[];
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_pid    text;
    v_lang   text;
    v_row    jsonb;
    v_ttl    int;
    v_tasks  jsonb;
BEGIN
    v_pid  := core.fn_handoff_person(CASE WHEN v_chat ~ '^[0-9]{1,18}$' THEN v_chat END);
    v_lang := agent.fn_person_lang(v_pid)->>'lang';

    IF COALESCE(p->>'chat_type', '') <> 'private' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_private_chat',
            'toast', core.fn_ui_text('core.toast.plan_private_only', v_lang));
    END IF;
    IF v_data <> 'handoff:' || v_domain || ':' || v_max || (CASE WHEN v_fix THEN ':fix' ELSE '' END)
       OR v_max !~ '^[0-9]{1,9}$' OR v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_handoff',
            'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
    END IF;
    SELECT e INTO v_row FROM jsonb_array_elements(core.fn_advisor_plan_status(v_chat)) e WHERE e->>'domain' = v_domain;
    IF v_row IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_handoff',
            'toast', core.fn_ui_text('core.toast.area_unavailable', v_lang));
    END IF;
    IF (v_row->>'can_write')::boolean IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'owner_only',
            'toast', core.fn_ui_text('core.toast.plan_owner_only', v_lang));
    END IF;

    IF v_fix THEN
        WITH reg AS (
            SELECT (e->>'task_id')::int AS id, e->'call' AS call, e->>'status' AS status
              FROM jsonb_array_elements(core.fn_handoff_register(v_domain, v_chat)) e
             WHERE (e->>'possible_now')::boolean AND (e->>'task_id')::int <= v_max::int
        ), redo AS (
            UPDATE agent.handoff_tasks t SET status = 'working', blocked_code = NULL, claimed_at = now()
              FROM reg WHERE t.id = reg.id AND reg.status = 'deferred' AND t.status = 'deferred'
            RETURNING t.id, t.kind, t.payload, t.text, t.why, t.wanted
        ), follow AS (
            INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, why, wanted,
                                             open_point_id, follows_task_id, status, claimed_at)
            SELECT o.domain, o.package, o.person_id, o.section_key, o.topic, o.kind, o.payload, o.text, o.why, reg.call,
                   o.open_point_id, o.id, 'working', now()
              FROM reg JOIN agent.handoff_tasks o ON o.id = reg.id
             WHERE reg.status IN ('done', 'cancelled')
            ON CONFLICT (follows_task_id) WHERE follows_task_id IS NOT NULL DO NOTHING
            RETURNING id, kind, payload, text, why, wanted
        )
        SELECT array_agg(x.id) INTO v_ids FROM (SELECT id FROM redo UNION ALL SELECT id FROM follow) x;
        -- eigene Anweisung: die eben angelegten Korrekturen sind erst danach sichtbar (fn_handoff_rest liest die Zeile)
        SELECT jsonb_agg(jsonb_build_object('id', t.id, 'kind', t.kind, 'payload', t.payload, 'text', t.text, 'why', t.why,
                                            'wanted', t.wanted, 'rest', core.fn_handoff_rest(t.id)) ORDER BY t.id)
          INTO v_tasks FROM agent.handoff_tasks t WHERE t.id = ANY (v_ids);
        IF v_tasks IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open',
                'toast', core.fn_ui_text('core.toast.handoff_nothing_open', v_lang));
        END IF;
        RETURN jsonb_build_object('ok', true, 'route', 'handoff', 'domain', v_domain,
            'task_ids', (SELECT jsonb_agg(e->'id' ORDER BY (e->>'id')::int) FROM jsonb_array_elements(v_tasks) e),
            'tasks', v_tasks);
    END IF;

    v_ttl := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
    WITH c AS (
        UPDATE agent.handoff_tasks t
           SET status = 'working', claimed_at = now()
         WHERE t.domain = v_domain AND t.person_id = v_pid AND t.id <= v_max::int
           AND (t.status = 'open' OR (t.status = 'working' AND t.claimed_at < now() - make_interval(mins => v_ttl)))
        RETURNING t.id, t.kind, t.payload, t.text, t.why, t.wanted
    )
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'payload', c.payload, 'text', c.text, 'why', c.why,
                                        'wanted', c.wanted, 'rest', core.fn_handoff_rest(c.id)) ORDER BY c.id)
      INTO v_tasks FROM c;
    IF v_tasks IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open',
            'toast', core.fn_ui_text('core.toast.handoff_nothing_open', v_lang));
    END IF;
    RETURN jsonb_build_object('ok', true, 'route', 'handoff', 'domain', v_domain,
        'task_ids', (SELECT jsonb_agg(e->'id' ORDER BY (e->>'id')::int) FROM jsonb_array_elements(v_tasks) e),
        'tasks', v_tasks);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handle_handoff_cb(jsonb) FROM public;
