-- ============================================================
-- agent.fn_note_proactive_turn (traegt eine proaktive Nachricht ins Gedaechtnis nach)
--   Crons schreiben in kein Agenten-Gedaechtnis; antwortet jemand frei auf eine Rollout-Nachricht, kennt sie sonst niemand.
--   Nur Katalog-Schluessel mit Skalar-Parametern, nie freier Text. Router: Vier-Zeilen-Form wie agent.fn_set_router_button_turn; Agent: Paar [Proactive message] + Struktur.
--   p: {chat_id, agent ('agent.<x>' oder 'orchestrator'), via ('agent.<x>', nur Router: der Agent, dem die Nachricht gehoert), msg:[{kind:'tpl', value, params}]}. Ungueltig oder Tabelle fehlt: no-op, nie RAISE.
--   RUECKGABE {ok:true, recorded}. Tests: tests/db/core/test_fn_note_proactive_turn.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_note_proactive_turn(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat   text := COALESCE(p->>'chat_id', '');
    v_agent  text := COALESCE(p->>'agent', '');
    v_msg    jsonb := p->'msg';
    v_label  CONSTANT text := '[Proactive message]';
    v_meta   CONSTANT jsonb := '{"additional_kwargs":{},"response_metadata":{}}';
    v_table  text;
    v_tool   text;
    v_call   text;
    v_payload text;
    v_no     CONSTANT jsonb := '{"ok":true,"recorded":false}'::jsonb;
BEGIN
    IF v_chat !~ '^[0-9]{1,18}$' OR jsonb_typeof(v_msg) IS DISTINCT FROM 'array' OR jsonb_array_length(v_msg) = 0 THEN RETURN v_no; END IF;
    IF EXISTS (
        SELECT 1 FROM jsonb_array_elements(v_msg) m
         WHERE m->>'kind' IS DISTINCT FROM 'tpl'
            OR COALESCE(m->>'value', '') !~ '^[a-z][a-z0-9_]*(\.[a-z0-9_]+)+$'
            OR EXISTS (SELECT 1 FROM jsonb_each(COALESCE(m->'params', '{}'::jsonb)) e
                        WHERE NOT (jsonb_typeof(e.value) IN ('number', 'boolean')
                                   OR (jsonb_typeof(e.value) = 'string' AND length(e.value #>> '{}') <= 80 AND position('://' in (e.value #>> '{}')) = 0)
                                   OR (jsonb_typeof(e.value) = 'object' AND e.value ? 'kind')))) THEN
        RETURN v_no;
    END IF;
    v_payload := v_msg::text;

    IF v_agent = 'orchestrator' THEN
        IF to_regclass('agent.orchestrator_chat_memory') IS NULL THEN RETURN v_no; END IF;
        -- echter Route-Tool-Name wie agent.fn_set_router_button_turn: sonst haengt die Folgeantwort an einem unbekannten Werkzeug.
        IF COALESCE(p->>'via', '') !~ '^agent\.[a-z][a-z0-9_]*$' THEN RETURN v_no; END IF;
        v_tool := 'Call_' || replace(p->>'via', '.', '_') || '_';
        v_call := 'toolu_proactive_' || replace(gen_random_uuid()::text, '-', '');
        EXECUTE $q$
            INSERT INTO agent.orchestrator_chat_memory (session_id, message)
            SELECT $1, m FROM unnest($2::jsonb[]) WITH ORDINALITY AS t(m, ord) ORDER BY ord
        $q$ USING v_chat, ARRAY[
            v_meta || jsonb_build_object('type', 'human', 'content', v_label),
            v_meta || jsonb_build_object('type', 'ai', 'content', '[]'::jsonb, 'invalid_tool_calls', '[]'::jsonb,
                'tool_calls', jsonb_build_array(jsonb_build_object('id', v_call, 'name', v_tool, 'type', 'tool_call', 'args', jsonb_build_object('input', v_label)))),
            v_meta || jsonb_build_object('type', 'tool', 'name', v_tool, 'tool_call_id', v_call,
                'content', jsonb_build_array(jsonb_build_object('output', v_payload))::text),
            v_meta || jsonb_build_object('type', 'ai', 'content', 'NOFRAME', 'invalid_tool_calls', '[]'::jsonb, 'tool_calls', '[]'::jsonb)
        ];
        RETURN '{"ok":true,"recorded":true}'::jsonb;
    END IF;

    IF v_agent !~ '^agent\.[a-z][a-z0-9_]*$' THEN RETURN v_no; END IF;
    v_table := split_part(v_agent, '.', 2) || '_chat_memory';
    IF to_regclass(format('agent.%I', v_table)) IS NULL THEN RETURN v_no; END IF;
    EXECUTE format($q$
        INSERT INTO agent.%I (session_id, message)
        SELECT $1, m FROM unnest($2::jsonb[]) WITH ORDINALITY AS t(m, ord) ORDER BY ord
    $q$, v_table) USING v_chat, ARRAY[
        v_meta || jsonb_build_object('type', 'human', 'content', v_label),
        v_meta || jsonb_build_object('type', 'ai', 'content', v_payload, 'invalid_tool_calls', '[]'::jsonb, 'tool_calls', '[]'::jsonb)
    ];
    RETURN '{"ok":true,"recorded":true}'::jsonb;
EXCEPTION WHEN OTHERS THEN
    RETURN v_no;
END;
$$;
REVOKE ALL ON FUNCTION agent.fn_note_proactive_turn(jsonb) FROM public;
