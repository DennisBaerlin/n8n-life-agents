-- ============================================================
-- fn_set_router_button_turn (ATOMIC WRITE — Knopf-Lauf im Router-Gedaechtnis nachtragen)
--   Ein Knopf startet einen Agenten am Router vorbei, das memoryPostgresChat-Gedaechtnis sieht den Lauf also nicht. Stand
--   dort zuletzt die Frage eines anderen Spezialisten, ging die Antwort an diesen, auch mit Folge-Bindung; eine
--   schaerfere Prompt-Regel half nicht, der Lauf im Verlauf schon. Nach dem Relay schreibt
--   diese fn den Lauf in der Zeilenform eines normalen Router-Turns: Mensch, Tool-Aufruf, Tool-Ergebnis, Signal.
--   Tabelle fehlt (frische DB, n8n legt sie beim ersten Gebrauch an) / kein Privatchat / Agent ungueltig / Antwort leer =
--   no-op. Nie RAISE (der Relay ist schon gelaufen).
--   p: { chat_id, agent ('agent.<name>', build-fix aus dem Arm, nie LLM), output (die weitergereichte Antwort) }
--   Rueckgabe: {ok:true, recorded}
--   Tests: tests/db/core/test_fn_set_router_button_turn.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_set_router_button_turn(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_chat    text := COALESCE(p->>'chat_id', '');
    v_agent   text := COALESCE(p->>'agent', '');
    v_output  text := COALESCE(p->>'output', '');
    v_tool    text;
    v_call_id text;
    v_label   CONSTANT text := '[Button tap]';
    v_meta    CONSTANT jsonb := '{"additional_kwargs":{},"response_metadata":{}}';
BEGIN
    IF to_regclass('agent.orchestrator_chat_memory') IS NULL
       OR v_chat !~ '^[0-9]{1,18}$'
       OR v_agent !~ '^agent\.[a-z][a-z0-9_]*$'
       OR btrim(v_output) = '' THEN
        RETURN jsonb_build_object('ok', true, 'recorded', false);
    END IF;

    v_tool    := 'Call_' || replace(v_agent, '.', '_') || '_';
    v_call_id := 'toolu_button_' || replace(gen_random_uuid()::text, '-', '');

    -- Feste Tabelle, Werte nur als Parameter (kein Caller-Input im SQL-Text); EXECUTE, weil die Tabelle beim CREATE
    -- der fn noch fehlen darf. Ein INSERT: die vier Zeilen bleiben zusammen und in dieser Reihenfolge.
    EXECUTE $q$
        INSERT INTO agent.orchestrator_chat_memory (session_id, message)
        SELECT $1, m FROM unnest($2::jsonb[]) WITH ORDINALITY AS t(m, ord) ORDER BY ord
    $q$ USING v_chat, ARRAY[
        v_meta || jsonb_build_object('type', 'human', 'content', v_label),
        v_meta || jsonb_build_object('type', 'ai', 'content', '[]'::jsonb, 'invalid_tool_calls', '[]'::jsonb,
            'tool_calls', jsonb_build_array(jsonb_build_object('id', v_call_id, 'name', v_tool, 'type', 'tool_call',
                                                               'args', jsonb_build_object('input', v_label)))),
        v_meta || jsonb_build_object('type', 'tool', 'name', v_tool, 'tool_call_id', v_call_id,
            'content', jsonb_build_array(jsonb_build_object('output', v_output))::text),
        v_meta || jsonb_build_object('type', 'ai', 'content', 'NOFRAME', 'invalid_tool_calls', '[]'::jsonb, 'tool_calls', '[]'::jsonb)
    ];

    RETURN jsonb_build_object('ok', true, 'recorded', true);
END;
$$;

REVOKE ALL ON FUNCTION agent.fn_set_router_button_turn(jsonb) FROM public;
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'context_ro') THEN
        REVOKE ALL ON FUNCTION agent.fn_set_router_button_turn(JSONB) FROM context_ro;
    END IF;
END $$;
