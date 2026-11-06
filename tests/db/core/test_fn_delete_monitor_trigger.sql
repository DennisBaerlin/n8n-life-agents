-- tests/db/core/test_fn_delete_monitor_trigger.sql
-- Testet fn_delete_monitor_trigger: Hard-DELETE (Trigger sind Config, kein Ledger).
-- Vertrag: Aufloesung per domain+label; Observations gehen per FK-CASCADE mit;
--   Erfolg -> {ok:true, trigger_id, observations_deleted}; not found -> {ok:false}.
BEGIN;

DO $$
DECLARE
  v     JSONB;
  v_id  INT;
  v_cnt INT;
BEGIN

  -- Fixture: Trigger + 2 Observations
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Doomed Trigger', 'trigger_type', 'date',
    'due_date', '2027-01-01', 'check_interval', '1 day'));
  v_id := (v->>'trigger_id')::int;
  INSERT INTO agent.monitor_observations (trigger_id, ok, value) VALUES (v_id, true, 1), (v_id, false, NULL);

  -- TEST 1: Delete entfernt Trigger + Observations (CASCADE), Count in der Rueckgabe
  v := agent.fn_delete_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'doomed trigger'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true
     OR (v->>'observations_deleted')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL delete [happy]: got %', v;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM agent.monitor_triggers WHERE id = v_id;
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL delete [happy]: Trigger-Zeile noch da';
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM agent.monitor_observations WHERE trigger_id = v_id;
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL delete [happy]: Observations nicht kaskadiert';
  END IF;
  RAISE NOTICE 'PASS delete [Hard-DELETE + Observation-CASCADE]';

  -- TEST 2: not found -> {ok:false}
  v := agent.fn_delete_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'No Such Trigger'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete [not found]: got %', v;
  END IF;
  RAISE NOTICE 'PASS delete [not found -> ok:false]';

END $$;

ROLLBACK;
