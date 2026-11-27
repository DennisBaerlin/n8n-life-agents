-- ============================================================
-- fn_reopen_handoff_task (ATOMIC WRITE) -- Abbruch-Zweig der Karten, die eine vereinbarte Plan-Aufgabe tragen
--   Jedes Werkzeug mit handoff_task_id ruft sie, wenn seine Karte nicht bestaetigt wurde (abgebrochen, abgelaufen, vom
--   Owner abgelehnt, nicht zustellbar): die Aufgabe ist sofort wieder offen statt bis zur Claim-Frist gesperrt. War sie
--   durch einen frueheren Teil schon erledigt (mehrere vereinbarte Aufrufe, einer nicht bestaetigt), kommen die noch nicht
--   eingetragenen Aufrufe als neue offene Aufgabe wieder: finance.fn_handoff_diff nennt sie (Eintraege mit call).
--   Delegiert an das Core-Fenster core.fn_reopen_handoff_task (agent.handoff_tasks ist finance_rw verschlossen).
--   Eingabe p: { handoff_task_id, chat_id }. Ohne handoff_task_id (Karte ausserhalb des Eintragens) {ok:true} ohne Wirkung.
--   Rueckgabe sonst unveraendert aus dem Core-Fenster: {ok:true, task_id, status, follow_task_id?} |
--   {ok:false, code:'handoff_task_invalid', reason}.
--   Tests: tests/db/finance/test_fn_reopen_handoff_task.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reopen_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_id      text := btrim(COALESCE(p->>'handoff_task_id', ''));
    v_missing jsonb;
BEGIN
    IF v_id = '' THEN
        RETURN jsonb_build_object('ok', true);
    END IF;
    IF v_id ~ '^[0-9]{1,9}$' THEN
        SELECT jsonb_agg(d->'call') INTO v_missing FROM jsonb_array_elements(finance.fn_handoff_diff(v_id::int)) d WHERE d ? 'call';
    END IF;
    RETURN core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_id, 'chat_id', p->>'chat_id')
               || CASE WHEN v_missing IS NOT NULL THEN jsonb_build_object('missing', v_missing) ELSE '{}'::jsonb END);
END;
$$;
