-- ============================================================
-- fn_release_handoff_tasks (ATOMIC WRITE) — gibt beanspruchte Plan-Aufgaben nach einem gescheiterten Buchhalter-Start frei
--   p: { task_ids: [int, ...] } (die task_ids aus core.fn_handle_handoff_cb; fehlend/ungueltig -> released 0). working -> open, claimed_at NULL; andere
--   Zustaende bleiben (eine schon erledigte Aufgabe wird nie wieder offen). Rueckgabe {ok:true, released}.
--   Aufgerufen vom Orchestrator (Host-Cred) im Fehler-Ausgang von 'Run handoff <domain>'.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_release_handoff_tasks(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_n int;
BEGIN
    UPDATE agent.handoff_tasks
       SET status = 'open', claimed_at = NULL
     WHERE status = 'working'
       AND id IN (SELECT (e #>> '{}')::int FROM jsonb_array_elements(
                      CASE WHEN jsonb_typeof(p->'task_ids') = 'array' THEN p->'task_ids' ELSE '[]'::jsonb END) e
                  WHERE (e #>> '{}') ~ '^[0-9]{1,9}$');
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN jsonb_build_object('ok', true, 'released', v_n);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_release_handoff_tasks(jsonb) FROM public;
