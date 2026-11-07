-- ============================================================
-- core.fn_cancel_handoff_task(p) — schliesst eine vereinbarte Plan-Aufgabe ohne Buchung
--   p: { handoff_task_id, chat_id, reason: skipped | done_elsewhere }. skipped -> cancelled (der Nutzer will den Punkt
--   nicht eintragen), done_elsewhere -> done (erledigt ohne passendes Tool, z. B. kind other). Erlaubt aus open und
--   working (der Nutzer darf einen Punkt auch vor dem Durchgehen ueberspringen); nur Aufgaben der Person des Absenders
--   (core.fn_handoff_person). Erfolg {ok:true, task_id, status, text}; korrigierbar {ok:false, code, reason}.
--   Endzustaende aendert der Trigger agent.fn_handoff_tasks_final_guard ohnehin nie.
--   Aufgerufen ueber finance.fn_cancel_handoff_task (agent.finance.tool_cancel_handoff_task, hinter der Karte).
--   SECURITY DEFINER, EXECUTE an <pkg>_rw via core.fn_provision_package_roles. Tests: tests/db/core/test_fn_handoff_tasks.sql
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
    v_t      record;
BEGIN
    IF v_reason NOT IN ('skipped', 'done_elsewhere') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_reason', 'reason', 'reason must be skipped or done_elsewhere.');
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
    IF v_t.status NOT IN ('open', 'working') THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_closed',
            'reason', 'Handoff task ' || v_id || ' is already ' || v_t.status || '.');
    END IF;
    UPDATE agent.handoff_tasks
       SET status = CASE v_reason WHEN 'skipped' THEN 'cancelled' ELSE 'done' END, closed_at = now()
     WHERE id = v_t.id;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id,
        'status', CASE v_reason WHEN 'skipped' THEN 'cancelled' ELSE 'done' END, 'text', v_t.text);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_cancel_handoff_task(jsonb) FROM public;
