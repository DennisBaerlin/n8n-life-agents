-- ============================================================
-- fn_defer_handoff_task (ATOMIC WRITE) -- Write-fn von agent.finance.tool_defer_handoff_task (hinter der Karte)
--   Stellt eine vereinbarte Plan-Aufgabe zurueck, die sich so noch nicht eintragen laesst (open|working -> deferred), statt den
--   vereinbarten Wert in Notizen zu parken; der Korrektur-Schritt bietet sie wieder an, sobald es geht. Delegiert an das
--   Core-Fenster core.fn_defer_handoff_task (agent.handoff_tasks ist finance_rw verschlossen; dort die Pruefung des Codes gegen
--   die Katalog-Keys finance.handoff.blocked.<code>).
--   Eingabe p: { handoff_task_id, chat_id, blocked_code }.
--   Erfolg {ok:true, task_id, status:'deferred', blocked_code, text, card_lines} (finance.fn_handoff_card_head: Stelle in der
--   Runde und der vereinbarte Satz; der Probelauf zeigt sie auf der Karte); korrigierbar unveraendert aus dem Core-Fenster
--   ({ok:false, code: unknown_blocked_code (+ valid_codes) | handoff_task_invalid | handoff_task_closed, reason}).
--   Tests: tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_defer_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_r jsonb := core.fn_defer_handoff_task(jsonb_build_object(
                     'handoff_task_id', p->>'handoff_task_id', 'chat_id', p->>'chat_id', 'blocked_code', p->>'blocked_code'));
BEGIN
    IF (v_r->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_r;
    END IF;
    RETURN v_r || jsonb_build_object('card_lines', finance.fn_handoff_card_head((v_r->>'task_id')::int, v_r->>'text'));
END;
$$;
