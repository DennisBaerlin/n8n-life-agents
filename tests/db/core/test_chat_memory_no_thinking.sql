-- tests/db/core/test_chat_memory_no_thinking.sql
-- Gesetz: agent.*_chat_memory traegt keine thinking-/redacted_thinking-Bloecke. Gilt fuer zur Laufzeit angelegte Tabellen,
-- auch unter der nicht-superuser Rolle, die der n8n-Memory-Knoten nutzt; Text und Tool-Bloecke bleiben unveraendert.
BEGIN;
CREATE ROLE zz_memory_writer NOLOGIN;
GRANT USAGE, CREATE ON SCHEMA agent TO zz_memory_writer;

SET LOCAL ROLE zz_memory_writer;
CREATE TABLE IF NOT EXISTS agent.zz_nt_chat_memory (id serial PRIMARY KEY, session_id varchar(255) NOT NULL, message jsonb NOT NULL);
INSERT INTO agent.zz_nt_chat_memory (session_id, message) VALUES
  ('a', '{"type":"ai","content":[{"type":"thinking","thinking":"x","signature":"s"},{"type":"redacted_thinking","data":"d"},{"type":"text","text":"bleibt"},{"type":"tool_use","id":"t1","name":"n","input":{"a":1}}],"tool_calls":[{"id":"t1","name":"n","args":{"a":1}}]}'),
  ('b', '{"type":"ai","content":"nur Text"}'),
  ('c', '{"type":"tool","content":"Ergebnis","tool_call_id":"t1"}'),
  ('d', '{"type":"ai","content":[{"type":"thinking","thinking":"","signature":"s"}]}');
RESET ROLE;

DO $$
DECLARE v JSONB;
BEGIN
  SELECT message INTO v FROM agent.zz_nt_chat_memory WHERE session_id = 'a';
  IF v->'content' <> '[{"type":"text","text":"bleibt"},{"type":"tool_use","id":"t1","name":"n","input":{"a":1}}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL Bloecke nicht gefiltert: %', v;
  END IF;
  IF v->'tool_calls'->0->>'id' <> 't1' THEN RAISE EXCEPTION 'FAIL tool_calls verloren: %', v; END IF;
  IF (SELECT message->>'content' FROM agent.zz_nt_chat_memory WHERE session_id = 'b') <> 'nur Text' THEN RAISE EXCEPTION 'FAIL Text-Zeile'; END IF;
  IF (SELECT message->>'tool_call_id' FROM agent.zz_nt_chat_memory WHERE session_id = 'c') <> 't1' THEN RAISE EXCEPTION 'FAIL Tool-Zeile'; END IF;
  -- Ein leeres Inhalts-Array lehnt die API ab -> leerer Text.
  IF (SELECT message->'content' FROM agent.zz_nt_chat_memory WHERE session_id = 'd') <> '""'::jsonb THEN RAISE EXCEPTION 'FAIL nur-Denkblock-Zeile'; END IF;

  UPDATE agent.zz_nt_chat_memory SET message = '{"type":"ai","content":[{"type":"thinking","thinking":"y","signature":"z"},{"type":"text","text":"neu"}]}' WHERE session_id = 'b';
  IF (SELECT message->'content' FROM agent.zz_nt_chat_memory WHERE session_id = 'b') <> '[{"type":"text","text":"neu"}]'::jsonb THEN RAISE EXCEPTION 'FAIL UPDATE-Weg'; END IF;
END $$;

-- Altbestand: eine Tabelle von vor der Sperre (ohne Trigger, mit Denkblock); die Reinigung der Migration nutzt dieselbe Funktion.
ALTER TABLE agent.zz_nt_chat_memory DISABLE TRIGGER USER;
INSERT INTO agent.zz_nt_chat_memory (session_id, message) VALUES ('old', '{"type":"ai","content":[{"type":"thinking","thinking":"x","signature":"s"},{"type":"tool_use","id":"t9","name":"n","input":{}}]}');
ALTER TABLE agent.zz_nt_chat_memory ENABLE TRIGGER USER;
DO $$
DECLARE v_first JSONB; v_second JSONB;
BEGIN
  v_first := agent.fn_strip_thinking_blocks((SELECT message FROM agent.zz_nt_chat_memory WHERE session_id = 'old'));
  v_second := agent.fn_strip_thinking_blocks(v_first);
  IF v_first->'content' <> '[{"type":"tool_use","id":"t9","name":"n","input":{}}]'::jsonb OR v_first IS DISTINCT FROM v_second THEN
    RAISE EXCEPTION 'FAIL Reinigung %', v_first;
  END IF;
END $$;

-- Bestand + handgesetzter Vorgaenger: Trigger strip_thinking samt Event-Trigger fuer neue Tabellen muss V036 konfliktfrei abraeumen.
CREATE FUNCTION agent.zz_bridge_row() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RETURN NEW; END $$;
CREATE FUNCTION agent.zz_bridge_ddl() RETURNS event_trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM 'strip_thinking'; END $$;
DO $$ BEGIN CREATE EVENT TRIGGER zz_bridge ON ddl_command_end WHEN TAG IN ('CREATE TABLE') EXECUTE FUNCTION agent.zz_bridge_ddl(); END $$;
CREATE TRIGGER strip_thinking BEFORE INSERT ON agent.zz_nt_chat_memory FOR EACH ROW EXECUTE FUNCTION agent.zz_bridge_row();
DO $$
BEGIN
  IF agent.fn_chat_memory_cleanup() <> 1 THEN RAISE EXCEPTION 'FAIL Bestand nicht genau eine Zeile'; END IF;
  IF (SELECT message->'content' FROM agent.zz_nt_chat_memory WHERE session_id = 'old') <> '[{"type":"tool_use","id":"t9","name":"n","input":{}}]'::jsonb THEN
    RAISE EXCEPTION 'FAIL Bestand nicht bereinigt';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'agent.zz_nt_chat_memory'::regclass AND tgname = 'strip_thinking') THEN RAISE EXCEPTION 'FAIL Vorgaenger-Trigger steht noch'; END IF;
  IF EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'zz_bridge') THEN RAISE EXCEPTION 'FAIL Vorgaenger-Event-Trigger steht noch'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'agent.zz_nt_chat_memory'::regclass AND tgname = 'trg_chat_memory_strip_thinking') THEN RAISE EXCEPTION 'FAIL Sperre weg'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_event_trigger WHERE evtname = 'chat_memory_guard_ddl') THEN RAISE EXCEPTION 'FAIL eigener Event-Trigger weg'; END IF;
  IF agent.fn_chat_memory_cleanup() <> 0 THEN RAISE EXCEPTION 'FAIL nicht idempotent'; END IF;
END $$;

-- Fremdkoerper: Tabelle mit passendem Namen, aber ohne message-Spalte, muss anlegbar und beschreibbar bleiben.
CREATE TABLE agent.zz_nomsg_chat_memory (id serial PRIMARY KEY, note text);
INSERT INTO agent.zz_nomsg_chat_memory (note) VALUES ('ok');
ROLLBACK;
