-- ============================================================
-- core.fn_complete_handoff_task(p) — schliesst eine vereinbarte Plan-Aufgabe nach dem erfolgreichen Write ab
--   p: { handoff_task_id, chat_id, entered_refs? [{type, id}] }. Prueft wie core.fn_handoff_task_check (working oder in dieser
--   Runde wieder freigegeben, Person des Absenders) und setzt working|open -> done, closed_at = now(), close_reason entered,
--   entered_refs = die angelegten oder geaenderten Sachen (Provenienz fuer das Ersatzweg-Register). Laeuft in derselben
--   Transaktion wie der Write der Ziel-fn (finance.fn_with_handoff): die Buchung und das "erledigt" fallen zusammen oder gar
--   nicht. Erfolg {ok:true, task_id, status:'done', part}; ein weiterer Teil derselben Runde (Pruef-fn part:true) haengt nur
--   seine entered_refs an, der Status bleibt. Sonst die Ablehnung der Pruef-fn; Aufgabe inzwischen nicht mehr working|open
--   -> {ok:false, code:'handoff_task_invalid', reason}.
--   SECURITY DEFINER, EXECUTE an <pkg>_rw via core.fn_provision_package_roles.
--   Tests: tests/db/core/test_fn_handoff_tasks.sql, tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_complete_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chk  jsonb := core.fn_handoff_task_check(p);
    v_refs jsonb := CASE WHEN jsonb_typeof(p->'entered_refs') = 'array' AND jsonb_array_length(p->'entered_refs') > 0
                         THEN p->'entered_refs' END;
BEGIN
    IF (v_chk->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_chk;
    END IF;
    IF (v_chk->>'part')::boolean THEN
        IF v_refs IS NOT NULL THEN
            UPDATE agent.handoff_tasks SET entered_refs = COALESCE(entered_refs, '[]'::jsonb) || v_refs
             WHERE id = (v_chk->>'task_id')::int AND status = 'done';
        END IF;
        RETURN jsonb_build_object('ok', true, 'task_id', (v_chk->>'task_id')::int, 'status', 'done', 'part', true);
    END IF;
    UPDATE agent.handoff_tasks SET status = 'done', closed_at = now(), close_reason = 'entered', entered_refs = v_refs
     WHERE id = (v_chk->>'task_id')::int AND status IN ('working', 'open');
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || (v_chk->>'task_id') || ' changed in the meantime.');
    END IF;
    RETURN jsonb_build_object('ok', true, 'task_id', (v_chk->>'task_id')::int, 'status', 'done', 'part', false);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_complete_handoff_task(jsonb) FROM public;
