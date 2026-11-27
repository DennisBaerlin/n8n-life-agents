-- ============================================================
-- fn_cancel_handoff_task (ATOMIC WRITE) -- Write-fn von agent.finance.tool_cancel_handoff_task (hinter der Karte)
--   Schliesst eine vereinbarte Plan-Aufgabe ohne Buchung: reason done_elsewhere (steht schon im System -> done),
--   dropped (nicht mehr eintragen -> cancelled) oder skipped (bleibt offen, working -> open). Delegiert an das Core-Fenster
--   core.fn_cancel_handoff_task (agent.handoff_tasks ist finance_rw verschlossen).
--   Eingabe p: { handoff_task_id, chat_id, reason, ref_type?, ref_name? }. done_elsewhere nur mit gefundener Sache: ref_type
--   (account | savings_goal | savings_plan | recurring_payment | pension | insurance | loan) + ref_name, aufgeloest ueber
--   finance.fn_handoff_resolve_ref; sie wird als entered_refs vermerkt. Abhaken ohne Sache gibt es nicht, weil die Karte
--   sagen muss, was im System steht.
--   Erfolg {ok:true, task_id, status, text, card_title_key, card_lines}: Kopf finance.fn_handoff_card_head (Stelle in der
--   Runde core.hitl.handoff_pos {k, n}, dann core.hitl.handoff_note {text}), bei done_elsewhere
--   dazu finance.label.handoff_in_system (Name der Sache aus den Daten) und finance.label.handoff_stays_open (offener Rest
--   der Aufgabe, sonst leer). card_title_key = Titel-Key der Karte je Grund (finance.hitl.cancel_handoff_task_done_elsewhere |
--   _dropped; fehlt bei skipped, das ohne Karte laeuft), das Werkzeug liest ihn aus dem Probelauf. Korrigierbar: {ok:false, code:'nothing_to_tick', reason} (keine Sache genannt oder
--   gefunden), {ok:false, code:'handoff_ref_ambiguous', candidates, reason}, sonst unveraendert aus dem Core-Fenster.
--   Tests: tests/db/finance/test_fn_with_handoff.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_cancel_handoff_task(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
    v_ref  jsonb;
    v_type text := lower(btrim(COALESCE(p->>'ref_type', '')));
    -- wie core.fn_cancel_handoff_task normalisiert: sonst umginge ' done_elsewhere' die Suche nach der Sache
    v_why  text := lower(btrim(COALESCE(p->>'reason', '')));
    v_refs jsonb;
    v_r    jsonb;
    v_head jsonb;
BEGIN
    IF v_why = 'done_elsewhere' THEN
        IF v_type NOT IN ('account', 'savings_goal', 'savings_plan', 'recurring_payment', 'pension', 'insurance', 'loan')
           OR NULLIF(btrim(COALESCE(p->>'ref_name', '')), '') IS NULL THEN
            RETURN jsonb_build_object('ok', false, 'code', 'nothing_to_tick',
                'reason', 'Name the thing that is already in the system (ref_type and ref_name). If nothing is entered yet, enter it '
                       || 'with its tool instead of ticking it off.');
        END IF;
        v_ref := finance.fn_handoff_resolve_ref(v_type, p->>'ref_name', NULL);
        IF (v_ref->>'hits')::int = 0 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'nothing_to_tick',
                'reason', format('Nothing called "%s" (%s) is in the system. Enter it with its tool instead of ticking it off.',
                                 p->>'ref_name', v_type));
        ELSIF (v_ref->>'hits')::int > 1 THEN
            RETURN jsonb_build_object('ok', false, 'code', 'handoff_ref_ambiguous', 'candidates', v_ref->'candidates',
                'reason', format('"%s" matches %s entries. Ask the user which one.', p->>'ref_name', v_ref->>'hits'));
        END IF;
        v_refs := jsonb_build_array(jsonb_build_object('type', v_type, 'id', (v_ref->'candidates'->0->>'id')::int));
    END IF;
    v_r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', p->>'handoff_task_id', 'chat_id', p->>'chat_id',
               'reason', v_why) || CASE WHEN v_refs IS NOT NULL THEN jsonb_build_object('entered_refs', v_refs) ELSE '{}'::jsonb END);
    IF (v_r->>'ok')::boolean IS NOT TRUE THEN
        RETURN v_r;
    END IF;
    v_head := finance.fn_handoff_card_head((v_r->>'task_id')::int, v_r->>'text');
    IF v_refs IS NOT NULL THEN
        RETURN v_r || jsonb_build_object('card_title_key', 'finance.hitl.cancel_handoff_task_done_elsewhere', 'card_lines', v_head || jsonb_build_array(
            jsonb_build_object('label', 'finance.label.handoff_in_system', 'kind', 'text', 'value', v_ref->>'name'),
            jsonb_build_object('label', 'finance.label.handoff_stays_open', 'kind', 'text',
                               'value', core.fn_handoff_tasks_read(ARRAY[(v_r->>'task_id')::int])->0->'rest')));
    END IF;
    RETURN v_r || CASE WHEN v_why = 'dropped'
                       THEN jsonb_build_object('card_title_key', 'finance.hitl.cancel_handoff_task_dropped') ELSE '{}'::jsonb END
        || jsonb_build_object('card_lines', v_head);
END;
$$;

-- fn_handoff_card_head: die ersten Zeilen jeder Karte zu einer vereinbarten Plan-Aufgabe ohne Buchung (zurueckstellen, nicht
-- mehr eintragen, abhaken): Stelle in der Runde (core.fn_handoff_position; fehlt ohne Claim), dann der vereinbarte Satz.
-- Dieselbe Reihenfolge wie auf der Eintrags-Karte (finance.fn_with_handoff), damit die Zaehlung ueber alle Karten einer
-- Runde lueckenlos ist.
CREATE OR REPLACE FUNCTION finance.fn_handoff_card_head(p_task_id int, p_text text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pos jsonb := core.fn_handoff_position(p_task_id);
BEGIN
    RETURN CASE WHEN v_pos IS NOT NULL
                THEN jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_pos', 'params', v_pos))
                ELSE '[]'::jsonb END
        || jsonb_build_array(jsonb_build_object('kind', 'note', 'value', 'core.hitl.handoff_note',
                                                'params', jsonb_build_object('text', p_text)));
END;
$$;
