-- tests/db/core/test_fn_set_router_button_turn.sql
-- Testet agent.fn_set_router_button_turn: ein Knopf startet einen Agenten am Router vorbei; danach traegt der Orchestrator
-- den Lauf in Zeilenform des Router-Gedaechtnisses nach. Ohne ihn stand dort zuletzt die Frage eines anderen Spezialisten,
-- und die Antwort landete trotz Folge-Bindung dort. Fehlende Tabelle/ungueltige Eingabe = no-op.
BEGIN;

DO $$
DECLARE
  v_res JSONB;
  v_tool_id TEXT;
BEGIN
  -- Ohne Tabelle (frische DB: n8n legt sie erst beim ersten Gebrauch an) -> no-op
  IF to_regclass('agent.orchestrator_chat_memory') IS NULL THEN
    v_res := agent.fn_set_router_button_turn('{"chat_id":"42","agent":"agent.guide","output":"x"}'::jsonb);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'recorded')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL button_turn [ohne Tabelle]: %', v_res; END IF;
    RAISE NOTICE 'PASS button_turn [ohne Tabelle -> no-op]';
    -- Form wie der n8n-Knoten memoryPostgresChat sie anlegt
    CREATE TABLE agent.orchestrator_chat_memory (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
  END IF;

  DELETE FROM agent.orchestrator_chat_memory WHERE session_id IN ('777001', '777002');
  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('777002', '{"type":"ai","content":"anderer Chat"}');

  -- TEST 1: vier Zeilen in Betriebsform und Reihenfolge, Tool-Name aus dem Agenten, Antwort woertlich in der tool-Zeile
  v_res := agent.fn_set_router_button_turn('{"chat_id":"777001","agent":"agent.finance_advisor","output":"Stimmt \"Punkt 1\"?"}'::jsonb);
  IF (v_res->>'recorded')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL button_turn [recorded]: %', v_res; END IF;
  IF (SELECT string_agg(message->>'type', ',' ORDER BY id) FROM agent.orchestrator_chat_memory WHERE session_id = '777001') <> 'human,ai,tool,ai' THEN
    RAISE EXCEPTION 'FAIL button_turn [Zeilenfolge]'; END IF;
  SELECT message->'tool_calls'->0->>'id' INTO v_tool_id FROM agent.orchestrator_chat_memory
   WHERE session_id = '777001' AND jsonb_array_length(message->'tool_calls') = 1;
  IF v_tool_id !~ '^[a-zA-Z0-9_-]+$' THEN RAISE EXCEPTION 'FAIL button_turn [Tool-Kennung]: %', v_tool_id; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.orchestrator_chat_memory
                  WHERE session_id = '777001' AND message->>'type' = 'tool' AND message->>'tool_call_id' = v_tool_id
                    AND message->>'name' = 'Call_agent_finance_advisor_'
                    AND ((message->>'content')::jsonb)->0->>'output' = 'Stimmt "Punkt 1"?') THEN
    RAISE EXCEPTION 'FAIL button_turn [tool-Zeile]'; END IF;
  IF (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '777001' ORDER BY id DESC LIMIT 1) <> 'NOFRAME' THEN
    RAISE EXCEPTION 'FAIL button_turn [Signal]'; END IF;
  IF (SELECT message->'tool_calls'->0->>'name' FROM agent.orchestrator_chat_memory
       WHERE session_id = '777001' AND jsonb_array_length(message->'tool_calls') = 1) <> 'Call_agent_finance_advisor_' THEN
    RAISE EXCEPTION 'FAIL button_turn [Tool-Aufruf]'; END IF;
  IF (SELECT count(*) FROM agent.orchestrator_chat_memory WHERE session_id = '777002') <> 1 THEN
    RAISE EXCEPTION 'FAIL button_turn [anderer Chat]'; END IF;
  RAISE NOTICE 'PASS button_turn [vier Zeilen in Betriebsform, nur dieser Chat]';

  -- TEST 2: ungueltig -> nichts geschrieben, nie ein Fehler (der Relay ist schon gelaufen)
  v_res := agent.fn_set_router_button_turn('{"chat_id":"-100123","agent":"agent.guide","output":"x"}'::jsonb);
  IF (v_res->>'recorded')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL button_turn [Gruppenchat]: %', v_res; END IF;
  v_res := agent.fn_set_router_button_turn('{"chat_id":"777001","agent":"drop table","output":"x"}'::jsonb);
  IF (v_res->>'recorded')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL button_turn [Agent]: %', v_res; END IF;
  v_res := agent.fn_set_router_button_turn('{"chat_id":"777001","agent":"agent.guide","output":"   "}'::jsonb);
  IF (v_res->>'recorded')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL button_turn [leer]: %', v_res; END IF;
  IF (SELECT count(*) FROM agent.orchestrator_chat_memory WHERE session_id = '777001') <> 4 THEN
    RAISE EXCEPTION 'FAIL button_turn [ungueltig schrieb]'; END IF;
  RAISE NOTICE 'PASS button_turn [Gruppenchat / ungueltiger Agent / leere Antwort -> nichts geschrieben]';
END $$;

ROLLBACK;
