-- ============================================================
-- core.fn_cancel_handoff_task(p) — eine vereinbarte Plan-Aufgabe ohne Werkzeug-Buchung weiterfuehren
--   p: { handoff_task_id, chat_id, reason, entered_refs? }.
--     dropped        -> cancelled, close_reason dropped (bewusst nicht mehr eintragen; auch aus deferred)
--     done_elsewhere -> done, close_reason done_elsewhere, optional entered_refs [{type, id}] = die Sache, die schon im
--                       System steht (gefunden hat sie das Paket vor dem Aufruf; ohne Sache zeigt es keine Karte)
--     skipped        -> "ueberspringen" streicht nicht: working -> open (claimed_at bleibt, damit "Eintrag k von n" der
--                       Runde stabil bleibt), open bleibt open. Fehlt reason, gilt skipped (der nicht-zerstoerende Weg).
--   Erlaubt aus open und working; aus deferred nur dropped (deferred -> done gibt es nicht, code handoff_task_deferred).
--   Nur Aufgaben der Person des Absenders (core.fn_handoff_person). Erfolg {ok:true, task_id, status, text};
--   korrigierbar {ok:false, code: invalid_reason | handoff_task_invalid | handoff_task_closed | handoff_task_deferred, reason}.
--   Endzustaende aendert der Trigger agent.fn_handoff_tasks_final_guard ohnehin nie.
--   Aufgerufen ueber finance.fn_cancel_handoff_task (agent.finance.tool_cancel_handoff_task, hinter der Karte).
--   SECURITY DEFINER, EXECUTE an <pkg>_rw via core.fn_provision_package_roles. Tests: tests/db/core/test_fn_handoff_tasks.sql,
--   tests/db/core/test_fn_defer_handoff_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_cancel_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id     text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_reason text := COALESCE(NULLIF(btrim(p->>'reason'), ''), 'skipped');
    v_pid    text := core.fn_handoff_person(p->>'chat_id');
    v_refs   jsonb := CASE WHEN jsonb_typeof(p->'entered_refs') = 'array' AND jsonb_array_length(p->'entered_refs') > 0
                           THEN p->'entered_refs' END;
    v_t      record;
    v_status text;
BEGIN
    IF v_reason NOT IN ('dropped', 'done_elsewhere', 'skipped') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reason',
            'reason', 'reason must be dropped (do not enter it anymore), done_elsewhere (already in the system) or skipped (keep it open).');
    END IF;
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT id, text, status, person_id INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int FOR UPDATE;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user.');
    END IF;
    IF v_t.status IN ('done', 'cancelled') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_closed',
            'reason', 'Handoff task ' || v_id || ' is already ' || v_t.status || '.');
    END IF;
    IF v_t.status = 'deferred' AND v_reason <> 'dropped' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_deferred',
            'reason', 'Handoff task ' || v_id || ' waits for an update; it can only be dropped.');
    END IF;

    IF v_reason = 'skipped' THEN
        UPDATE agent.handoff_tasks SET status = 'open' WHERE id = v_t.id AND status = 'working';
        v_status := 'open';
    ELSIF v_reason = 'dropped' THEN
        UPDATE agent.handoff_tasks SET status = 'cancelled', blocked_code = NULL, closed_at = now(), close_reason = 'dropped'
         WHERE id = v_t.id;
        v_status := 'cancelled';
    ELSE
        UPDATE agent.handoff_tasks SET status = 'done', closed_at = now(), close_reason = 'done_elsewhere', entered_refs = v_refs
         WHERE id = v_t.id;
        v_status := 'done';
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'status', v_status, 'text', v_t.text);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_cancel_handoff_task(jsonb) FROM public;
