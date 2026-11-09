-- ============================================================
-- finance.fn_account_emoji_picker(p_chat_id, p_account_id) -- Lesepfad von tool_send_account_emoji_picker, entscheidet nach Rolle
--   Owner: {ok:true, card} = Seite 0 (fn_account_emoji_page) in seiner Sprache. Mitglied: {ok:false, reason} mit den Zeichen samt
--   Bezeichnung, weil der Tipp direkt speichert, tool_set_account aber fuer Mitglieder eine Owner-Karte verlangt: Das Mitglied nennt
--   ein Zeichen, tool_set_account schickt die Karte an den Owner. Unbekannter Absender oder fehlendes Konto: {ok:false, reason}.
--   Tests: tests/db/finance/test_fn_handle_account_emoji_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_emoji_picker(p_chat_id text, p_account_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_s    jsonb;
    v_lang text;
    v_card jsonb;
    v_list text;
BEGIN
    IF COALESCE(p_chat_id, '') ~ '^[0-9]{1,18}$' THEN v_s := agent.fn_resolve_sender(p_chat_id::bigint); END IF;
    IF v_s->>'person_id' IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'The sender is not a known household member.');
    END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';
    v_card := finance.fn_account_emoji_page(p_account_id, 0, v_lang);
    IF v_card IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'This account no longer exists.');
    END IF;
    IF v_s->>'role' = 'owner' THEN
        RETURN jsonb_build_object('ok', true, 'card', v_card);
    END IF;
    SELECT string_agg(e || ' ' || core.fn_ui_text('finance.emoji.' || to_hex(ascii(e)), v_lang), ', ' ORDER BY n)
      INTO v_list
      FROM unnest(finance.fn_account_emoji_choices()) WITH ORDINALITY AS t(e, n);
    RETURN jsonb_build_object('ok', false, 'reason',
        'Buttons are only available to the owner. Show the user these signs as a list and ask which one they want: ' || v_list
        || '. Do not call this tool again; once they name one, call tool_set_account.');
END;
$$;
