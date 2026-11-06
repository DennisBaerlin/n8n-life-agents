-- tests/db/core/test_fn_monitor_due.sql
-- Testet fn_monitor_due(p_now): Due-Selection des Heartbeat-Crons.
-- Vertrag: liefert NUR status='armed' mit next_check_at <= p_now; fired/disabled nie;
--          run_ts = p_now (eine Uhr fuer den ganzen Lauf); Spalten fuer den Acquisition-
--          Branch (acquisition_method, acquisition_spec, prompt) sind dabei.
BEGIN;
-- Roter Faden: die Bestandsfaelle laufen mit fester Uhr (07:10) -> Erinnerungs-Fenster hier auf den ganzen Tag;
-- das Fenster-Verhalten selbst prueft test_fn_monitor_evaluate (Block "Erinnerungs-Fenster").
INSERT INTO core.config (package, category, key, value) VALUES
  ('core', 'general', 'reminders_from', '0'), ('core', 'general', 'reminders_until', '24')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE
  v_now   CONSTANT TIMESTAMPTZ := '2026-06-10 07:10+02'::timestamptz;
  v_count INT;
  v_row   RECORD;
BEGIN

  -- Fixtures: 4 Trigger — due / nicht due / fired / disabled
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec,
     due_date, check_interval, next_check_at, status)
  VALUES
    ('__test__', 'due now',     'date', 'none', '{}', '2027-01-01', INTERVAL '1 day', v_now - INTERVAL '1 hour', 'armed'),
    ('__test__', 'not yet due', 'date', 'none', '{}', '2027-01-01', INTERVAL '1 day', v_now + INTERVAL '1 hour', 'armed'),
    ('__test__', 'fired one',   'date', 'none', '{}', '2027-01-01', INTERVAL '1 day', v_now - INTERVAL '1 hour', 'fired'),
    ('__test__', 'disabled one','date', 'none', '{}', '2027-01-01', INTERVAL '1 day', v_now - INTERVAL '1 hour', 'disabled');

  -- TEST 1: nur der armed+faellige Trigger kommt zurueck
  SELECT COUNT(*) INTO v_count FROM agent.fn_monitor_due(v_now)
   WHERE domain = '__test__';
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_monitor_due [selection]: erwartet 1 due-Zeile, got %', v_count;
  END IF;
  SELECT * INTO v_row FROM agent.fn_monitor_due(v_now) WHERE domain = '__test__';
  IF v_row.label IS DISTINCT FROM 'due now' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_due [selection]: falsche Zeile, got %', v_row.label;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_due [nur armed + faellig]';

  -- TEST 2: run_ts = p_now (Injektion — eine Uhr fuer Due-Set und Evaluate)
  IF v_row.run_ts IS DISTINCT FROM v_now THEN
    RAISE EXCEPTION 'FAIL fn_monitor_due [run_ts]: erwartet %, got %', v_now, v_row.run_ts;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_due [run_ts = p_now]';

  -- TEST 3: Acquisition-Spalten fuer den Workflow-Branch vorhanden
  IF v_row.acquisition_method IS DISTINCT FROM 'none'
     OR v_row.acquisition_spec IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_monitor_due [spalten]: acquisition_method/spec fehlen';
  END IF;
  RAISE NOTICE 'PASS fn_monitor_due [Acquisition-Spalten]';

  -- TEST 4: Cadence respektiert — nach Advance (next_check_at in Zukunft) nicht mehr due
  UPDATE agent.monitor_triggers SET next_check_at = v_now + INTERVAL '23 hours'
   WHERE domain = '__test__' AND label = 'due now';
  SELECT COUNT(*) INTO v_count FROM agent.fn_monitor_due(v_now) WHERE domain = '__test__';
  IF v_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_monitor_due [cadence]: erwartet 0 nach Advance, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_due [Cadence respektiert]';

END $$;

ROLLBACK;
