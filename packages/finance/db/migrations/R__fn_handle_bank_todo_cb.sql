-- ============================================================
-- finance.fn_handle_bank_todo_cb(p) -- Registry-Handler des Callback-Prefix 'btodo' (member_permeable)
--   Knopf btodo:<erste-id>:<max-id>: erledigt alle sichtbaren Punkte derselben Bank und desselben Inhabers bis max-id.
--   Owner alles, erwachsenes Mitglied (partner) nur eigene, Kind nichts. Doppeltipp oder geloeschter Punkt: Hinweis.
--   p: {data, chat_id, chat_type}. Rueckgabe {ok:true, closed, toast} | {ok:false, reason, toast}. Nie RAISE.
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
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN v_s := agent.fn_resolve_sender(v_chat::bigint); END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';
    IF v_s->>'role' IS NULL OR v_s->>'role' NOT IN ('owner', 'partner') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed', 'toast', core.fn_ui_text('finance.bank_todo.toast_not_yours', v_lang));
    END IF;
    IF v_data <> 'btodo:' || v_first || ':' || v_max OR v_first !~ '^[0-9]{1,9}$' OR v_max !~ '^[0-9]{1,9}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
    END IF;
    -- Der erste Punkt muss nur noch existieren: Er kann schon gebucht sein, waehrend andere derselben Nachricht offen sind.
    v_item := finance.fn_bank_todo_item(v_first::int);
    IF v_item IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
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
    IF v_n = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'nothing_open', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
    END IF;
    RETURN jsonb_build_object('ok', true, 'closed', v_n, 'toast', core.fn_ui_text('finance.bank_todo.toast_done', v_lang));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error', 'toast', core.fn_ui_text('finance.bank_todo.toast_nothing', v_lang));
END;
$$;
