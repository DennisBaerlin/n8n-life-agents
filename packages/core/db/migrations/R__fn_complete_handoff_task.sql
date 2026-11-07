-- ============================================================
-- core.fn_complete_handoff_task(p) — schliesst eine vereinbarte Plan-Aufgabe nach dem erfolgreichen Write ab
--   p: { handoff_task_id, chat_id }. Prueft wie core.fn_handoff_task_check (working, Person des Absenders) und setzt
--   working -> done, closed_at = now(). Laeuft in DERSELBEN Transaktion wie der Write der Ziel-fn (finance.fn_with_handoff):
--   die Buchung und das "erledigt" fallen zusammen oder gar nicht. Erfolg {ok:true, task_id, status:'done'}; sonst die
--   Ablehnung der Pruef-fn. SECURITY DEFINER, EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_complete_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chk jsonb := core.fn_handoff_task_check(p);
BEGIN
    IF (v_chk->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_chk;
    END IF;
    UPDATE agent.handoff_tasks SET status = 'done', closed_at = now()
     WHERE id = (v_chk->>'task_id')::int AND status = 'working';
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || (v_chk->>'task_id') || ' changed in the meantime.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', (v_chk->>'task_id')::int, 'status', 'done');
END;
$$;
REVOKE ALL ON FUNCTION core.fn_complete_handoff_task(jsonb) FROM public;
