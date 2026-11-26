-- ============================================================
-- fn_with_handoff (ATOMIC WRITE) — fuehrt einen finance-Write fuer eine vereinbarte Plan-Aufgabe aus
--   Jede Schreib-fn, die eine Vormerkung erfuellen kann, ruft sie als erste Anweisung, wenn p.handoff_task_id gesetzt ist:
--   RETURN finance.fn_with_handoff('<eigene Signatur>'::regprocedure, p). Welche das sind, steht im Manifest
--   (advisors.finance.handoff_tools); contract_lint prueft Werkzeug-Eingang und diesen Aufruf.
--   Eingabe: p_fn regprocedure (die aufrufende fn), p jsonb (deren Payload inkl. handoff_task_id, chat_id).
--   Ablauf in derselben Transaktion: (1) core.fn_handoff_task_check (Aufgabe working, oder in dieser Runde schon erledigt =
--   weiterer Teil derselben Vormerkung, nur fuer eine fn_create_*; Person des Absenders aus p.chat_id), sonst {ok:false,
--   code:'handoff_task_invalid', reason} ohne Write; (2) die Ziel-fn mit p ohne handoff_task_id, waehrend der transaktionslokale Wert
--   finance.handoff_task_id gesetzt ist (finance.fn_bank_note_recorded haengt damit den Bank-Punkt an die Vormerkung und
--   gibt die Kurz-Zeile statt des Bank-Absatzes); (3) nur bei ok:true core.fn_complete_handoff_task -> done (ein weiterer
--   Teil aendert nichts) und eine Kartenzeile core.hitl.handoff_note {text} am Ende von card_lines (Probelauf = Karte "Aus
--   dem Plan-Gespraech: ..."), plus handoff_task_id im Ergebnis. ok:false der Ziel-fn -> unveraendert zurueck, die Aufgabe
--   bleibt working.
--   p_fn ist eine Build-/Code-Konstante der aufrufenden fn, nie Nutzer-Input (dynamischer EXECUTE nur darauf).
--   SECURITY INVOKER (laeuft unter finance_rw wie die Ziel-fn). Tests: tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_with_handoff(p_fn regprocedure, p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
-- kein gepinnter search_path: er galt sonst auch in der Ziel-fn, die unqualifizierte Namen ueber den Rollen-Pfad aufloest
AS $$
DECLARE
    v_chk  jsonb;
    v_r    jsonb;
    v_done jsonb;
BEGIN
    v_chk := core.fn_handoff_task_check(p);
    IF (v_chk->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_chk;
    END IF;
    -- Ein weiterer Teil legt etwas Neues an; eine zweite Aenderung derselben Sache waere eine Wiederholung.
    IF (v_chk->>'part')::boolean AND (SELECT pr.proname FROM pg_catalog.pg_proc pr WHERE pr.oid = p_fn) NOT LIKE 'fn\_create\_%' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'handoff_task_invalid',
            'reason', 'Handoff task ' || (v_chk->>'task_id') || ' is already done; this change was booked for it. Do not book it again.');
    END IF;
    -- Ein RAISE der Ziel-fn bricht die Transaktion bzw. den Savepoint ab; damit faellt auch der lokale Wert zurueck.
    PERFORM set_config('finance.handoff_task_id', v_chk->>'task_id', true);
    EXECUTE format('SELECT %s($1)', p_fn::regproc) INTO v_r USING (p - 'handoff_task_id');
    -- nur fuer diesen einen Write: ein spaeterer Aufruf derselben Transaktion gehoert nicht zur Vormerkung
    PERFORM set_config('finance.handoff_task_id', '', true);
    IF (v_r->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_r;
    END IF;
    v_done := core.fn_complete_handoff_task(p);
    IF (v_done->>'ok')::boolean IS NOT TRUE THEN
        -- zwischen Pruefung und Abschluss geaendert (paralleler Lauf): den Write nicht ohne "erledigt" stehen lassen
        RAISE EXCEPTION 'finance.fn_with_handoff: handoff task % could not be completed: %', p->>'handoff_task_id', v_done->>'reason';
    END IF;
    RETURN v_r || jsonb_build_object(
        'handoff_task_id', (v_chk->>'task_id')::int,
        'card_lines', COALESCE(v_r->'card_lines', '[]'::jsonb) || jsonb_build_array(jsonb_build_object(
            'kind', 'note', 'value', 'core.hitl.handoff_note', 'params', jsonb_build_object('text', v_chk->>'text'))));
END;
$$;
