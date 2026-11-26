-- tests/db/core/test_fn_handoff_overview_mark.sql
-- core.fn_handoff_overview_mark: setzt den Schluessel von Schritt 1 fest (mit Version des gueltigen Plans), ungueltige Eingaben sind ein No-op.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'x', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id', 'erika', 'first_name', 'Erika', 'last_name', 'M', 'role', 'owner', 'birth_date', '1980-05-20', 'telegram_user_id', 111, 'language', 'de')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
DO $$
DECLARE v JSONB;
BEGIN
  -- ohne gueltigen Plan: Version 0, wirft nicht
  v := core.fn_handoff_overview_mark('{"domain":"__m__","chat_id":"111","max_task_id":"7"}');
  IF (v->>'marked')::boolean IS NOT TRUE OR core.fn_plan_rollout_latch('__m__:household:0:handoff:7') <> 'done' THEN RAISE EXCEPTION 'FAIL mark v0 %', v; END IF;
  -- mit gueltigem Plan: dessen Version; derselbe Schluessel wie core.fn_handoff_overview
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES ('__m__', 'p', 'active', 3);
  v := core.fn_handoff_overview_mark('{"domain":"__m__","chat_id":"111","max_task_id":"7"}');
  IF (v->>'marked')::boolean IS NOT TRUE OR core.fn_plan_rollout_latch('__m__:household:3:handoff:7') <> 'done' THEN RAISE EXCEPTION 'FAIL mark v3 %', v; END IF;
  IF core.fn_handoff_latch_key('__m__', '111', 7) IS DISTINCT FROM '__m__:household:3:handoff:7' THEN RAISE EXCEPTION 'FAIL latch_key'; END IF;
  v := core.fn_handoff_overview_mark('{"domain":"","max_task_id":"x"}');
  IF (v->>'marked')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL noop %', v; END IF;
END $$;
ROLLBACK;
