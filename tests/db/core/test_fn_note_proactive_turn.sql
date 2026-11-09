-- tests/db/core/test_fn_note_proactive_turn.sql
-- agent.fn_note_proactive_turn: Router-Form, Agent-Paar, Ablehnung von freiem Text, URL, ungueltigem Agenten; no-op ohne Tabelle.
BEGIN;
CREATE TABLE IF NOT EXISTS agent.orchestrator_chat_memory (id serial PRIMARY KEY, session_id text, message jsonb);
CREATE TABLE IF NOT EXISTS agent.zz_chat_memory (id serial PRIMARY KEY, session_id text, message jsonb);
DO $$
DECLARE
  v JSONB;
  v_good JSONB := '[{"kind":"tpl","value":"core.rollout.scan_offer","params":{"n":2}}]';
BEGIN
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'orchestrator', 'via', 'agent.finance_advisor', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT TRUE OR (SELECT count(*) FROM agent.orchestrator_chat_memory WHERE session_id = '111') <> 4 THEN RAISE EXCEPTION 'FAIL router %', v; END IF;
  IF (SELECT message->>'content' FROM agent.orchestrator_chat_memory WHERE session_id = '111' ORDER BY id DESC LIMIT 1) <> 'NOFRAME' THEN RAISE EXCEPTION 'FAIL Signal'; END IF;

  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'agent.zz', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT TRUE OR (SELECT count(*) FROM agent.zz_chat_memory) <> 2 THEN RAISE EXCEPTION 'FAIL agent %', v; END IF;

  IF (SELECT message->'tool_calls'->0->>'name' FROM agent.orchestrator_chat_memory WHERE session_id = '111' ORDER BY id LIMIT 1 OFFSET 1) <> 'Call_agent_finance_advisor_' THEN RAISE EXCEPTION 'FAIL Tool-Name'; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'orchestrator', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL Router ohne via %', v; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'agent.gibtsnicht', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL Tabelle fehlt %', v; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'x; DROP', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL ungueltig %', v; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'agent.zz', 'msg', '[{"kind":"text","value":"frei"}]'::jsonb));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL freier Text %', v; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', '111', 'agent', 'agent.zz', 'msg', '[{"kind":"tpl","value":"core.x.y","params":{"u":"https://evil.example"}}]'::jsonb));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL URL %', v; END IF;
  v := agent.fn_note_proactive_turn(jsonb_build_object('chat_id', 'abc', 'agent', 'agent.zz', 'msg', v_good));
  IF (v->>'recorded')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL Chat %', v; END IF;
END $$;
ROLLBACK;
