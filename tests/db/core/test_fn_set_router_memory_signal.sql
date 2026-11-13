-- tests/db/core/test_fn_set_router_memory_signal.sql
-- Testet agent.fn_set_router_memory_signal: nach einem woertlich weitergereichten Spezialisten ersetzt der Orchestrator
-- seinen eigenen Router-Text im Chat-Gedaechtnis durch das Signal (sonst schreibt der Router eine
-- eigene Fassung, die der Nutzer nie sah, und ahmt sie in den Folge-Turns nach). Nur die juengste passende ai-Zeile
-- dieses Chats, nur ein gueltiges Signal, fehlende Tabelle = no-op.
BEGIN;

DO $$
DECLARE
  v_res JSONB;
BEGIN
  -- Ohne Tabelle (frische DB: n8n legt sie erst beim ersten Gebrauch an) -> no-op
  IF to_regclass('agent.orchestrator_chat_memory') IS NULL THEN
    v_res := agent.fn_set_router_memory_signal('{"chat_id":"42","raw":"x","signal":"NOFRAME"}'::jsonb);
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'updated')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL router_memory [ohne Tabelle]: %', v_res; END IF;
    RAISE NOTICE 'PASS router_memory [ohne Tabelle -> no-op]';
    -- Form wie der n8n-Knoten memoryPostgresChat sie anlegt
    CREATE TABLE agent.orchestrator_chat_memory (id SERIAL PRIMARY KEY, session_id VARCHAR(255) NOT NULL, message JSONB NOT NULL);
  END IF;

  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES
    ('__t_rms_1', '{"type":"ai","content":"Eigene Fassung alt"}'),
    ('__t_rms_1', '{"type":"tool","content":"[{\"output\":\"Spezialist\"}]","name":"Call_agent_finance_"}'),
    ('__t_rms_1', '{"type":"ai","content":"Eigene Fassung neu"}'),
    ('__t_rms_2', '{"type":"ai","content":"Eigene Fassung neu"}');

  -- TEST 1: juengste passende ai-Zeile des Chats -> Signal; anderer Chat und aeltere Zeile bleiben
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_1","raw":"Eigene Fassung neu","signal":"FRAME"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM true
     OR (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '__t_rms_1' ORDER BY id DESC LIMIT 1) <> 'FRAME'
     OR (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '__t_rms_2') <> 'Eigene Fassung neu'
     OR NOT EXISTS (SELECT 1 FROM agent.orchestrator_chat_memory WHERE session_id = '__t_rms_1' AND message->>'content' = 'Eigene Fassung alt') THEN
    RAISE EXCEPTION 'FAIL router_memory [ersetzen]: %', v_res; END IF;
  RAISE NOTICE 'PASS router_memory [juengste passende ai-Zeile -> Signal, sonst unberuehrt]';

  -- TEST 1b: steht schon das Signal da (der Router hielt sich an die Regel) -> kein Schreiben, updated false
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_1","raw":"FRAME","signal":"FRAME"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL router_memory [schon Signal]: %', v_res; END IF;
  RAISE NOTICE 'PASS router_memory [schon Signal -> kein Schreiben]';

  -- TEST 2: ungueltiges Signal, leerer/fremder Text -> nichts geaendert
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_2","raw":"Eigene Fassung neu","signal":"HALLO"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL router_memory [Signal ungueltig]: %', v_res; END IF;
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_2","raw":"","signal":"NOFRAME"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL router_memory [leer]: %', v_res; END IF;
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_2","raw":"anderer Text","signal":"NOFRAME"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM false
     OR (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '__t_rms_2') <> 'Eigene Fassung neu' THEN
    RAISE EXCEPTION 'FAIL router_memory [fremder Text]: %', v_res; END IF;
  RAISE NOTICE 'PASS router_memory [ungueltiges Signal / leer / fremder Text -> unveraendert]';

  -- TEST 3: ohne Werkzeug mit Vorschlags-Marker -> der bereinigte Text ersetzt die Router-Zeile; content = raw -> no-op
  INSERT INTO agent.orchestrator_chat_memory (session_id, message) VALUES ('__t_rms_3', jsonb_build_object('type', 'ai', 'content', E'Hallo!\nNEXT_STEP'));
  v_res := agent.fn_set_router_memory_signal(jsonb_build_object('chat_id', '__t_rms_3', 'raw', E'Hallo!\nNEXT_STEP', 'content', 'Hallo!'));
  IF (v_res->>'updated')::boolean IS DISTINCT FROM true
     OR (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '__t_rms_3') <> 'Hallo!' THEN
    RAISE EXCEPTION 'FAIL router_memory [Marker bereinigt]: %', v_res; END IF;
  v_res := agent.fn_set_router_memory_signal('{"chat_id":"__t_rms_3","raw":"Hallo!","content":"Hallo!"}'::jsonb);
  IF (v_res->>'updated')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL router_memory [content = raw]: %', v_res; END IF;
  RAISE NOTICE 'PASS router_memory [Marker-Zeile ohne Werkzeug -> bereinigter Text]';
END $$;

ROLLBACK;
