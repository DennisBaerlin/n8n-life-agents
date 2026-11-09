-- tests/db/core/test_fn_handoff_overview_mark.sql
-- core.fn_handoff_overview_mark: setzt den Schluessel von Schritt 1 fest, ungueltige Eingaben sind ein No-op.
BEGIN;
DO $$
DECLARE v JSONB;
BEGIN
  v := core.fn_handoff_overview_mark('{"domain":"__m__","chat_id":"111","max_task_id":"7"}');
  IF (v->>'marked')::boolean IS NOT TRUE OR core.fn_plan_rollout_latch('__m__:household:handoff:7') <> 'done' THEN RAISE EXCEPTION 'FAIL mark %', v; END IF;
  v := core.fn_handoff_overview_mark('{"domain":"","max_task_id":"x"}');
  IF (v->>'marked')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL noop %', v; END IF;
END $$;
ROLLBACK;
