-- ============================================================
-- core.fn_create_choice_prompt(p) — Antwort-Knoepfe aus der Marker-Zeile CHOICES (WRITE)
--   Der Orchestrator-Relay findet in der Antwort eines Agenten die Zeile "CHOICES a | b | c", entfernt sie aus dem Text und
--   ruft diese fn VOR dem Senden; die Knoepfe haengen an der Antwort selbst, danach core.fn_chat_prompt_sent.
--   Bei uns anders als ein Werkzeug je Frage: ein Text-Marker kostet keine
--   Iteration und ein choice-Tipp schreibt nichts; geprueft wird hier.
--   Gesetz: 2-3 Optionen, je 1..24 Zeichen nach btrim, keine Dubletten (ohne Gross-/Kleinschreibung), keine Links
--   (://, www., t.me/, @); sonst {ok:false, code:'invalid_choices'} -> der Relay verwirft den Marker still, nichts geschrieben.
--   Die Zeile ist sofort open (Art choice, Agent = p.agent). Eine offene choice des Chats wird superseded, eine offene
--   andere Frage geht zurueck in die Schlange (sie erscheint wieder, sobald die choice erledigt ist).
--   Eingabe p: {chat_id, agent ('agent.<x>'), options (Array oder JSON-String)}.
--   Rueckgabe {ok:true, prompt_id, buttons:[[{text, data}]]} | {ok:false, code, reason} mit code invalid_input
--   (chat_id/agent), invalid_choices, unknown_chat (keine bekannte Person) oder error (jeder Laufzeitfehler). Nie RAISE.
--   VOLATILE, INVOKER (Host-Cred), search_path gepinnt.
--   Tests: tests/db/core/test_chat_prompts.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_create_choice_prompt(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_agent  text := COALESCE(p->>'agent', '');
    v_opts   jsonb;
    v_pid    text;
    v_id     bigint;
    v_bad    constant jsonb := jsonb_build_object('ok', false, 'code', 'invalid_choices',
                 'reason', 'CHOICES needs 2-3 distinct options of at most 24 characters without links');
BEGIN
    IF NOT core.fn_chat_id_ok(v_chat) OR v_agent !~ '^agent\.[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'code', 'invalid_input', 'reason', 'chat_id and agent are required');
    END IF;
    BEGIN
        v_opts := core.fn_jsonb_list(p->'options');
    EXCEPTION WHEN OTHERS THEN
        RETURN v_bad;
    END;
    SELECT COALESCE(jsonb_agg(btrim(e #>> '{}') ORDER BY i), '[]'::jsonb) INTO v_opts
      FROM jsonb_array_elements(v_opts) WITH ORDINALITY AS x(e, i);
    IF jsonb_array_length(v_opts) NOT BETWEEN 2 AND 3
       OR EXISTS (SELECT 1 FROM jsonb_array_elements_text(v_opts) t
                   WHERE t = '' OR length(t) > 24 OR t ~* '(://|www\.|t\.me/|@)')
       OR (SELECT count(DISTINCT lower(t)) FROM jsonb_array_elements_text(v_opts) t) <> jsonb_array_length(v_opts) THEN
        RETURN v_bad;
    END IF;
    v_pid := core.fn_chat_person(v_chat)->>'person_id';
    IF v_pid IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'unknown_chat', 'reason', 'chat is not a known person');
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('chat_prompt:' || v_chat));
    UPDATE agent.chat_prompts SET status = 'superseded', decided_at = clock_timestamp()
     WHERE chat_id = v_chat AND status = 'open' AND kind = 'choice';
    UPDATE agent.chat_prompts SET status = 'queued'
     WHERE chat_id = v_chat AND status = 'open';
    INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, status, options, payload)
    VALUES (v_chat, v_pid, v_agent, 'choice', 'open',
            (SELECT jsonb_agg(jsonb_build_object('key', 'o' || i, 'label', t) ORDER BY i)
               FROM jsonb_array_elements_text(v_opts) WITH ORDINALITY AS x(t, i)),
            jsonb_build_object('label', (SELECT string_agg(t, ' | ' ORDER BY i) FROM jsonb_array_elements_text(v_opts) WITH ORDINALITY AS x(t, i))))
    RETURNING id INTO v_id;
    RETURN jsonb_build_object('ok', true, 'prompt_id', v_id, 'buttons', core.fn_render_prompt(v_id)->'buttons');
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'code', 'error', 'reason', SQLERRM);
END;
$$;
REVOKE ALL ON FUNCTION core.fn_create_choice_prompt(jsonb) FROM public;
