-- ============================================================
-- fn_cancel_handoff_task (ATOMIC WRITE) -- Write-fn von agent.finance.tool_cancel_handoff_task (hinter der Karte)
--   Ueberspringt eine vereinbarte Plan-Aufgabe (reason skipped -> cancelled) oder schliesst sie als anderweitig
--   erledigt (reason done_elsewhere -> done). Eingabe p: { handoff_task_id, chat_id, reason }. Delegiert an das
--   Core-Fenster core.fn_cancel_handoff_task (agent.handoff_tasks ist finance_rw verschlossen). Erfolg {ok:true,
--   task_id, status, text, card_lines:[core.hitl.handoff_note {text}]} (der Probelauf zeigt damit den Satz auf der
--   Karte); korrigierbar {ok:false, code, reason} (unveraendert aus dem Core-Fenster).
--   Tests: tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_cancel_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_r jsonb := core.fn_cancel_handoff_task(jsonb_build_object(
                     'handoff_task_id', p->>'handoff_task_id', 'chat_id', p->>'chat_id', 'reason', p->>'reason'));
BEGIN
    IF (v_r->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_r;
    END IF;
    RETURN v_r || jsonb_build_object('card_lines', jsonb_build_array(jsonb_build_object(
        'kind', 'note', 'value', 'core.hitl.handoff_note', 'params', jsonb_build_object('text', v_r->>'text'))));
END;
$$;
