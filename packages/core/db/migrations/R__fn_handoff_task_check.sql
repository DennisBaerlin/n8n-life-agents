-- ============================================================
-- core.fn_handoff_task_check(p) — darf dieser Write die vereinbarte Plan-Aufgabe abschliessen?
--   p: { handoff_task_id, chat_id }. Gueltig nur, wenn die Aufgabe existiert, working ist (per [Durchgehen] beansprucht)
--   und der Person des Absenders gehoert (core.fn_handoff_person). Erfolg {ok:true, task_id, kind, text}; sonst
--   {ok:false, code:'handoff_task_invalid', reason} (korrigierbar, kein RAISE). Nur lesend.
--   Konsumenten: finance.fn_with_handoff (Probelauf und Write der Ziel-fn), core.fn_complete_handoff_task.
--   SECURITY DEFINER (die Paket-Schreibrolle sieht agent.* nicht), EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_handoff_task_check(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_id  text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_pid text := core.fn_handoff_person(p->>'chat_id');
    v_t   record;
BEGIN
    IF v_id !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'handoff_task_id must be the numeric id from the handoff task list.');
    END IF;
    SELECT id, kind, text, status, person_id INTO v_t FROM agent.handoff_tasks WHERE id = v_id::int;
    IF NOT FOUND OR v_t.person_id IS DISTINCT FROM v_pid THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' does not exist for this user. Re-read the task list or leave handoff_task_id empty.');
    END IF;
    IF v_t.status <> 'working' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || v_id || ' is ' || v_t.status || ', not in progress. Do not book it again; leave handoff_task_id empty for a new entry.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', v_t.id, 'kind', v_t.kind, 'text', v_t.text);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_handoff_task_check(jsonb) FROM public;
