-- ============================================================
-- core.fn_answer_chat_prompt(p) — Registry-Handler des Callback-Prefix 'q' (member_permeable): Tipp auf eine offene Frage
--   callback_data q:<id>:<key>. Prueft, dann fuehrt die answer_fn der Art (core.prompt_kinds) aus und schliesst die Zeile.
--   Regeln (vor jedem Write, Toast in der Sprache des Tippenden):
--     * nur Privatchat (not_private_chat); bei offener Bestaetigungs-Karte im Chat gilt deren Sperre (card_open);
--     * Zeile fehlt -> unknown_prompt; Chat der Zeile <> Chat des Tippenden -> not_yours; Zeile nicht open -> outdated;
--       Schluessel nicht unter den Optionen -> unknown_option (veraltet/unbekannt: edit {keep_text} nimmt die Knoepfe weg);
--     * Schluessel note -> force_reply {text, placeholder} (Eingabefeld "Was soll anders sein?"), die Zeile bleibt offen;
--     * sonst answer_fn(jsonb {prompt (Zeile), key, chat_id, lang}) -> {ok, append?, then, continue?, toast?, keep_open?};
--       ok:false -> deren reason/toast und ggf. then/continue (die answer_fn setzt ihre Zeile dann selbst auf superseded, z. B.
--       Speichern beim Tipp abgelehnt); ok:true -> answered (answer_key, decided_at), es sei denn keep_open. Wirft die
--       answer_fn, gilt das als save_failed (nichts geschrieben, Zeile bleibt offen).
--   Rueckgabe {ok, toast?, edit?:{keep_text:true, append?}, force_reply?, then:'none'|'next'|'continue', continue?:{agent,
--   text, as:'message'|'task'}} | {ok:false, reason, toast[, edit][, then, continue]}; reasons not_private_chat, card_open,
--   unknown_prompt, not_yours, outdated, unknown_option, answer_fn_missing, save_failed, error. Nie RAISE (Dispatcher-Vertrag).
--   Feine Autorisierung (Schreibrecht am Plan) machen die answer_fns ueber die Write-fns, die sie rufen.
--   Familie: core.fn_prompt_answer_choice(p) = answer_fn der Art choice: der Optionstext laeuft weiter wie eine Nachricht
--   ({then:'continue', continue:{agent, text, as:'message'}, append '→ <Option>'}).
--   VOLATILE, INVOKER unter der Host-Cred des Dispatchers, search_path gepinnt.
--   Tests: tests/db/core/test_chat_prompts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_answer_chat_prompt(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data  text := COALESCE(p->>'data', '');
    v_idtxt text := split_part(v_data, ':', 2);
    v_key   text := split_part(v_data, ':', 3);
    v_chat  text := COALESCE(p->>'chat_id', '');
    v_pid   text;
    v_lang  text;
    v_row   agent.chat_prompts%ROWTYPE;
    v_fn    regprocedure;
    v_res   jsonb;
BEGIN
    v_pid  := core.fn_chat_person(v_chat)->>'person_id';
    v_lang := agent.fn_person_lang(v_pid)->>'lang';
    IF COALESCE(p->>'chat_type', '') <> 'private' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_private_chat',
            'toast', core.fn_ui_text('core.toast.prompt_private_only', v_lang));
    END IF;
    IF EXISTS (SELECT 1 FROM agent.hitl_pending h
                WHERE v_chat ~ '^[0-9]{1,18}$' AND h.chat_id = v_chat::bigint AND h.released_at IS NULL AND h.expires_at > now()) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'card_open',
            'toast', core.fn_ui_text('core.toast.prompt_card_open', v_lang));
    END IF;
    IF v_data <> 'q:' || v_idtxt || ':' || v_key OR v_idtxt !~ '^[0-9]{1,18}$' OR v_key !~ '^[a-z0-9_]{1,16}$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_prompt', 'edit', jsonb_build_object('keep_text', true),
            'toast', core.fn_ui_text('core.toast.prompt_outdated', v_lang));
    END IF;

    SELECT * INTO v_row FROM agent.chat_prompts WHERE id = v_idtxt::bigint FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_prompt', 'edit', jsonb_build_object('keep_text', true),
            'toast', core.fn_ui_text('core.toast.prompt_outdated', v_lang));
    END IF;
    IF v_row.chat_id <> v_chat THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_yours',
            'toast', core.fn_ui_text('core.toast.prompt_not_yours', v_lang));
    END IF;
    IF v_row.status <> 'open' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'outdated', 'edit', jsonb_build_object('keep_text', true),
            'toast', core.fn_ui_text('core.toast.prompt_outdated', v_lang));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_row.options) o WHERE o->>'key' = v_key) THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown_option', 'edit', jsonb_build_object('keep_text', true),
            'toast', core.fn_ui_text('core.toast.prompt_outdated', v_lang));
    END IF;
    IF v_key = 'note' THEN
        RETURN jsonb_build_object('ok', true, 'then', 'none',
            'force_reply', jsonb_build_object('text', core.fn_ui_text('core.prompt.note_ask', v_lang),
                                              'placeholder', core.fn_ui_text('core.prompt.note_placeholder', v_lang)));
    END IF;

    v_fn := to_regprocedure((SELECT k.answer_fn FROM core.prompt_kinds k WHERE k.kind = v_row.kind) || '(jsonb)');
    IF v_fn IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'answer_fn_missing',
            'toast', core.fn_ui_text('core.toast.prompt_outdated', v_lang));
    END IF;
    BEGIN
        EXECUTE format('SELECT %s($1)', v_fn::regproc) INTO v_res
          USING jsonb_build_object('prompt', to_jsonb(v_row), 'key', v_key, 'chat_id', v_chat, 'lang', v_lang);
    EXCEPTION WHEN OTHERS THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'save_failed',
            'toast', core.fn_ui_text('core.toast.prompt_save_failed', v_lang));
    END;
    IF (v_res->>'ok')::boolean IS NOT TRUE THEN
        RETURN jsonb_build_object('ok', false, 'reason', COALESCE(v_res->>'reason', 'save_failed'),
            'toast', COALESCE(v_res->>'toast', core.fn_ui_text('core.toast.prompt_save_failed', v_lang)))
            || CASE WHEN v_res ? 'then' THEN jsonb_build_object('then', v_res->'then', 'continue', v_res->'continue') ELSE '{}'::jsonb END;
    END IF;
    IF (v_res->>'keep_open')::boolean IS NOT TRUE THEN
        UPDATE agent.chat_prompts SET status = 'answered', answer_key = v_key, decided_at = clock_timestamp()
         WHERE id = v_row.id;
    END IF;
    RETURN jsonb_strip_nulls(jsonb_build_object('ok', true, 'toast', v_res->>'toast',
        'edit', jsonb_strip_nulls(jsonb_build_object('keep_text', true, 'append', v_res->>'append')),
        'then', COALESCE(v_res->>'then', 'next'), 'continue', v_res->'continue'));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error',
        'toast', core.fn_ui_text('core.toast.prompt_save_failed', v_lang));
END;
$$;
REVOKE ALL ON FUNCTION core.fn_answer_chat_prompt(jsonb) FROM public;

CREATE OR REPLACE FUNCTION core.fn_prompt_answer_choice(p jsonb)
RETURNS jsonb
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT jsonb_build_object('ok', true, 'append', '→ ' || (o->>'label'), 'then', 'continue',
               'continue', jsonb_build_object('agent', p->'prompt'->>'agent', 'text', o->>'label', 'as', 'message'))
      FROM jsonb_array_elements(p->'prompt'->'options') o
     WHERE o->>'key' = p->>'key';
$$;
REVOKE ALL ON FUNCTION core.fn_prompt_answer_choice(jsonb) FROM public;
