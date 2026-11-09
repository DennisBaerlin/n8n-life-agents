-- ============================================================
-- finance.fn_handle_account_emoji_cb(p) -- Registry-Handler des Callback-Prefix 'acem' (nicht member_permeable)
--   acem:<id>:<zeichen> speichert ueber fn_set_account OHNE HITL-Karte: bewusste Ausnahme (der Tipp des Owners ist die Bestaetigung,
--   das Zeichen rechnet nichts und ist sofort wieder aenderbar; docs/reference/packages.md). acem:<id>:more:<seite> schreibt nichts
--   und liefert die naechste Seite als choice_card (der Orchestrator sendet sie, Zweig 'Choice card?').
--   Alte Knoepfe sind harmlos: der letzte Tipp gilt, geschlossenes oder geloeschtes Konto = Hinweis-Toast.
--   p: {data, chat_id, chat_type}. Rueckgabe {ok:true, toast[, choice_card]} | {ok:false, reason, toast}. Nie RAISE.
--   Tests: tests/db/finance/test_fn_handle_account_emoji_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_handle_account_emoji_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data text := COALESCE(p->>'data', '');
    v_chat text := COALESCE(p->>'chat_id', '');
    v_m    text[] := regexp_match(v_data, '^acem:([0-9]{1,9}):(?:more:([0-3])|([^:]+))$');
    v_s    jsonb;
    v_lang text;
    v_id   int;
    v_res  jsonb;
    v_card jsonb;
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN v_s := agent.fn_resolve_sender(v_chat::bigint); END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';
    IF v_s->>'role' IS DISTINCT FROM 'owner' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed', 'toast', core.fn_ui_text('finance.toast.emoji_not_allowed', v_lang));
    END IF;
    IF v_m IS NULL OR (v_m[3] IS NOT NULL AND NOT v_m[3] = ANY(finance.fn_account_emoji_choices())) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown', 'toast', core.fn_ui_text('finance.toast.emoji_unavailable', v_lang));
    END IF;
    v_id := v_m[1]::int;
    -- fn_set_account prueft den Status nicht und wirft bei fehlendem Konto
    IF NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_id AND status = 'active') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'account_unavailable', 'toast', core.fn_ui_text('finance.toast.emoji_unavailable', v_lang));
    END IF;
    IF v_m[2] IS NOT NULL THEN
        v_card := finance.fn_account_emoji_page(v_id, v_m[2]::int, v_lang);
        RETURN jsonb_build_object('ok', true, 'toast', core.fn_ui_text('finance.toast.emoji_page', v_lang), 'choice_card', v_card);
    END IF;
    v_res := finance.fn_set_account(jsonb_build_object('account_id', v_id, 'emoji', v_m[3]));
    IF NOT (v_res->>'ok')::boolean THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'rejected', 'toast', core.fn_ui_text('finance.toast.emoji_unavailable', v_lang));
    END IF;
    RETURN jsonb_build_object('ok', true, 'toast', core.fn_ui_text('finance.toast.emoji_set', v_lang, jsonb_build_object('account', v_res->>'label')));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error', 'toast', core.fn_ui_text('finance.toast.emoji_unavailable', v_lang));
END;
$$;
