-- ============================================================
-- fn_setup_advance (WRITE, kein HITL) -- ein Schritt der Ersteinrichtung: Antwort speichern, Konto binden, Positionen einstellen
--   Eingabe: chat_id, table:{rows}, action (continue|cancel), question_key, answer, amount, historic_price (opt).
--   cancel beendet den Lauf (bestaetigte Daten bleiben). done schliesst ihn. Bei Schritt positions stellt sie die Zeilen ein.
--   RUECKGABE: fn_setup_next + {batch_id, staged, invalid, card}, {closed:true} oder die Rueckfrage/Ablehnung von fn_setup_answer.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_advance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_next JSONB;
    v_ans  JSONB;
    v_stg  JSONB;
BEGIN
    IF lower(COALESCE(p->>'action', 'continue')) = 'cancel' THEN
        RETURN finance.fn_setup_close(p) || jsonb_build_object('phase', 'cancelled',
            'say', 'The setup is cancelled. Already confirmed accounts and positions stay as they are; say so.');
    END IF;

    v_next := finance.fn_setup_next(p);
    IF (v_next->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_next;
    END IF;
    IF NULLIF(p->>'question_key', '') IS NOT NULL THEN
        v_ans := finance.fn_setup_answer(p || jsonb_build_object('item', v_next->'ask', 'account_id', v_next->>'account_id'));
        IF (v_ans->>'ok')::boolean IS DISTINCT FROM true OR (v_ans->>'saved')::boolean IS DISTINCT FROM true THEN
            RETURN v_ans;
        END IF;
        v_next := finance.fn_setup_next(p - 'historic_price');
        -- naechster offener Punkt braucht seinen eigenen Kurs-Abruf im Tool
        IF v_next->>'phase' = 'open_items' THEN
            RETURN v_next - 'ask' || jsonb_build_object('say', 'Saved. Call tool_import_setup (action continue) now for the next open point.');
        END IF;
    END IF;

    IF (v_next->>'account_id') IS NOT NULL THEN
        UPDATE finance.setup_session SET cash_account_id = (v_next->>'account_id')::int, updated_at = now()
        WHERE chat_id = p->>'chat_id' AND profile = v_next->>'profile' AND cash_account_id IS DISTINCT FROM (v_next->>'account_id')::int;
    END IF;

    IF v_next->>'phase' = 'positions' THEN
        v_stg := finance.fn_import_positions_from_export(p);
        IF (v_stg->>'ok')::boolean IS DISTINCT FROM true THEN
            RETURN v_stg;
        END IF;
        RETURN (v_next - 'positions') || v_stg || jsonb_build_object('positions', v_stg->'positions',
            'card', jsonb_build_object('tool', 'tool_commit_import', 'params', jsonb_build_object('batch_id', v_stg->'batch_id')));
    END IF;
    IF (v_next->>'done')::boolean THEN
        PERFORM finance.fn_setup_close(jsonb_build_object('chat_id', p->>'chat_id', 'profile', v_next->>'profile'));
        RETURN v_next || '{"closed":true}'::jsonb;
    END IF;
    RETURN v_next;
END;
$$;
