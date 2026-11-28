-- ============================================================
-- fn_handle_bank_todo_cb (CALLBACK HANDLER) -- Registry-Handler des Callback-Prefix 'btodo' (member_permeable)
--   Knopf btodo:<erste-id>:<max-id>: erledigt alle sichtbaren Punkte derselben Bank und desselben Inhabers bis max-id.
--   Owner alles, erwachsenes Mitglied (partner) nur eigene, Kind nichts. Doppeltipp oder geloeschter Punkt: Hinweis.
--   p: {data, chat_id, chat_type}. Rueckgabe {ok:true, closed, toast, edit} |
--   {ok:false, reason (not_allowed|unknown|nothing_open|error), toast, edit?}. Nie RAISE (EXCEPTION WHEN OTHERS).
--   edit (Registry-Feld, docs/package-contract.md §2) = die getippte Nachricht behaelt ihren Text, der Knopf verschwindet:
--   erledigt oder schon erledigt -> append = Ausgangs-Zeile finance.bank_todo.done_line[_generic] {bank} in der Sprache des
--   Tippenden; Punkt geloescht, vom System ersetzt oder unsichtbar -> nur Knopf weg. Kein edit bei not_allowed/unknown/error (Nachricht bleibt).
--   Tests: tests/db/finance/test_fn_handle_bank_todo_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_handle_bank_todo_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data  text := COALESCE(p->>'data', '');
    v_first text := split_part(v_data, ':', 2);
    v_max   text := split_part(v_data, ':', 3);
    v_chat  text := COALESCE(p->>'chat_id', '');
    v_s     jsonb;
    v_lang  text;
    v_item  jsonb;
    v_n     int;
    v_done  jsonb;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN v_s := agent.fn_resolve_sender(v_chat::bigint); END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';
    IF v_s->>'role' IS NULL OR v_s->>'role' NOT IN ('owner', 'partner') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed', 'toast', core.fn_ui_text('finance.bank_todo.toast_not_yours', v_lang));
    END IF;
    IF v_data <> 'btodo:' || v_first || ':' || v_max OR v_first !~ '^[0-9]{1,9}$' OR v_max !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
    END IF;
    -- Der erste Punkt muss nur noch existieren: er kann schon gebucht sein, waehrend andere derselben Nachricht offen sind.
    v_item := finance.fn_bank_todo_item(v_first::int);
    IF v_item IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang),
            'edit', jsonb_build_object('keep_text', true));
    END IF;
    IF v_s->>'role' <> 'owner' AND v_item->>'holder_person_id' IS DISTINCT FROM v_s->>'person_id' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed', 'toast', core.fn_ui_text('finance.bank_todo.toast_not_yours', v_lang));
    END IF;
    WITH d AS (
        UPDATE finance.bank_todos t SET status = 'done', closed_at = now()
          FROM (SELECT o.id, finance.fn_bank_todo_item(o.id) AS item
                  FROM finance.bank_todos o
                 WHERE o.status = 'open' AND o.id <= v_max::int AND finance.fn_bank_todo_visible(o.id)) c
         WHERE t.id = c.id
           AND c.item->>'bank' IS NOT DISTINCT FROM v_item->>'bank'
           AND c.item->>'holder_person_id' IS NOT DISTINCT FROM v_item->>'holder_person_id'
        RETURNING t.id)
    SELECT count(*) INTO v_n FROM d;
    v_done := jsonb_build_object('keep_text', true, 'append', CASE WHEN v_item->>'bank' IS NULL
        THEN core.fn_ui_text('finance.bank_todo.done_line_generic', v_lang)
        ELSE core.fn_ui_text('finance.bank_todo.done_line', v_lang, jsonb_build_object('bank', v_item->>'bank')) END);
    -- Nichts mehr offen: die Erledigt-Zeile nur, wenn der erste Punkt erledigt ist und kein Nachfolger fuer denselben Kopf
    -- offen steht. Sonst hat das System ihn ersetzt (fn_bank_note_recorded) oder er ist unsichtbar -> nur Knopf weg.
    IF v_n = 0 THEN
        IF NOT EXISTS (SELECT 1 FROM finance.bank_todos f WHERE f.id = v_first::int AND f.status = 'done'
                          AND NOT EXISTS (SELECT 1 FROM finance.bank_todos o WHERE o.head_id = f.head_id AND o.status = 'open')) THEN
            v_done := jsonb_build_object('keep_text', true);
        END IF;
        RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang),
            'edit', v_done);
    END IF;
    RETURN jsonb_build_object('ok', true, 'closed', v_n, 'toast', core.fn_ui_text('finance.bank_todo.toast_done', v_lang), 'edit', v_done);
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
END;
$$;
