-- tests/db/core/test_dry_run_monitor.sql
-- Probelauf vor der Karte (core.fn_dry_run) gegen die drei Monitor-Write-fns, genau wie die Tools ihn aufrufen
-- (agent.tool_{create,set,delete}_monitor_trigger): die DB lehnt VOR der Karte ab, und der Probelauf hinterlaesst nichts
-- (keine Trigger-Zeile, keine Observation, keine Aenderung). Der Vertrag {ok:false, reason} bleibt stabil.
BEGIN;

DO $$
DECLARE
  v_r    JSONB;
  v_id   INT;
  v_core INT;
  v_n0   INT;
  v_n    INT;
  v_obs0 INT;
  v_st   TEXT;
BEGIN
  SELECT count(*) INTO v_n0 FROM agent.monitor_triggers;
  SELECT count(*) INTO v_obs0 FROM agent.monitor_observations;

  -- ---------- create ----------
  v_r := core.fn_dry_run('agent.fn_create_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Probe Termin', 'trigger_type', 'date', 'acquisition_method', 'none',
      'due_date', '2099-01-01', 'check_interval', '1 day'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL dry_run monitor create [gueltig]: erwartet ok:true/dry_run:true, got %', v_r; END IF;
  SELECT count(*) INTO v_n FROM agent.monitor_triggers;
  IF v_n <> v_n0 THEN RAISE EXCEPTION 'FAIL dry_run monitor create: Trigger-Zeile nicht zurueckgerollt'; END IF;

  v_r := core.fn_dry_run('agent.fn_create_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Probe Schwelle', 'trigger_type', 'threshold', 'acquisition_method', 'web_search',
      'acquisition_prompt', 'Aktueller Preis.', 'comparator', 'sideways', 'threshold_value', 10,
      'expected_unit', 'EUR', 'check_interval', '1 day'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR coalesce(v_r->>'reason', '') = '' THEN
    RAISE EXCEPTION 'FAIL dry_run monitor create [ungueltig]: erwartet ok:false mit reason, got %', v_r; END IF;
  SELECT count(*) INTO v_n FROM agent.monitor_triggers;
  IF v_n <> v_n0 THEN RAISE EXCEPTION 'FAIL dry_run monitor create [ungueltig]: Zeile entstanden'; END IF;

  -- ---------- set / delete brauchen echte Trigger ----------
  v_r := agent.fn_create_monitor_trigger(jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Echter Termin', 'trigger_type', 'date', 'acquisition_method', 'none',
      'due_date', '2099-01-01', 'check_interval', '1 day'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL dry_run monitor Setup: %', v_r; END IF;
  v_id := (v_r->>'trigger_id')::int;
  INSERT INTO agent.monitor_observations (trigger_id, ok, value) VALUES (v_id, true, 1);
  SELECT status INTO v_st FROM agent.monitor_triggers WHERE id = v_id;

  v_r := core.fn_dry_run('agent.fn_set_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Echter Termin', 'check_interval', 'banana'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL dry_run monitor set [ungueltig]: erwartet ok:false, got %', v_r; END IF;
  v_r := core.fn_dry_run('agent.fn_set_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Echter Termin', 'status', 'disabled'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL dry_run monitor set [gueltig]: erwartet ok:true, got %', v_r; END IF;
  IF (SELECT status FROM agent.monitor_triggers WHERE id = v_id) IS DISTINCT FROM v_st THEN
    RAISE EXCEPTION 'FAIL dry_run monitor set: Status nicht zurueckgerollt'; END IF;

  -- Core-Systemtrigger: nie loeschbar -> schon der Probelauf lehnt ab, die Zeile bleibt
  UPDATE agent.monitor_triggers SET origin = 'core' WHERE id = v_id;
  v_core := v_id;
  v_r := core.fn_dry_run('agent.fn_delete_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Echter Termin'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT ILIKE '%core system trigger%' THEN
    RAISE EXCEPTION 'FAIL dry_run monitor delete [Core-Trigger]: erwartet ok:false, got %', v_r; END IF;
  UPDATE agent.monitor_triggers SET origin = 'user' WHERE id = v_core;

  -- Nutzer-Trigger: Probelauf ok, Zeile + Observation bleiben
  v_r := core.fn_dry_run('agent.fn_delete_monitor_trigger(jsonb)'::regprocedure, jsonb_build_object(
      'domain', '__dryrun__', 'label', 'Echter Termin'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'observations_deleted')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL dry_run monitor delete [gueltig]: erwartet ok:true/observations_deleted 1, got %', v_r; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE id = v_id)
     OR (SELECT count(*) FROM agent.monitor_observations WHERE trigger_id = v_id) <> 1 THEN
    RAISE EXCEPTION 'FAIL dry_run monitor delete: Probelauf hat geloescht'; END IF;

  DELETE FROM agent.monitor_triggers WHERE id = v_id;
  IF (SELECT count(*) FROM agent.monitor_triggers) <> v_n0
     OR (SELECT count(*) FROM agent.monitor_observations) <> v_obs0 THEN
    RAISE EXCEPTION 'FAIL dry_run monitor: Reste im Bestand'; END IF;
  RAISE NOTICE 'PASS dry_run monitor [create/set/delete lehnen vor der Karte ab, hinterlassen nichts]';
END $$;

ROLLBACK;
