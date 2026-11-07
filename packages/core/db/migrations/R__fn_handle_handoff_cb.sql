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
--   Erfolg {ok:true, route:'handoff', domain, task_ids:[...], tasks:[{id, kind, payload, text}]} -> der Orchestrator
--   ('Handoff route?') startet den handoff_agent der Domain mit festem Auftrag; Dispatch-Fehler -> der Orchestrator gibt
--   die Claims mit core.fn_release_handoff_tasks frei. Sonst {ok:false, reason, toast}. Nie RAISE (Dispatcher-Vertrag).
--   VOLATILE (Claim), SECURITY INVOKER unter der Host-Cred des Dispatchers. Toasts in der Sprache des Tippenden.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql
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
    IF v_data <> 'handoff:' || v_domain || ':' || v_max OR v_max !~ '^[0-9]{1,9}$' OR v_pid IS NULL THEN
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

    v_ttl := COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'handoff_claim_ttl_minutes'), '')::int, 120);
    WITH c AS (
        UPDATE agent.handoff_tasks t
           SET status = 'working', claimed_at = now()
         WHERE t.domain = v_domain AND t.person_id = v_pid AND t.id <= v_max::int
           AND (t.status = 'open' OR (t.status = 'working' AND t.claimed_at < now() - make_interval(mins => v_ttl)))
        RETURNING t.id, t.kind, t.payload, t.text
    )
    SELECT jsonb_agg(jsonb_build_object('id', c.id, 'kind', c.kind, 'payload', c.payload, 'text', c.text) ORDER BY c.id)
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
