-- tests/db/core/test_fn_monitor_reset_unsent.sql
-- agent.fn_monitor_reset_unsent: Sendefehler im Heartbeat-Cron stellt die ausgeloesten Waechter wieder scharf.
-- Termine pruefen sofort wieder, Werte zum naechsten Prueftermin; Ratchet und last_value bleiben; ein Termin ueber
-- monitor.unsent_retry_days hinaus bleibt fired und steht in gave_up.
BEGIN;
INSERT INTO core.config (package, category, key, value) VALUES ('core', 'monitor', 'unsent_retry_days', '3')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;

DO $$
DECLARE
  v JSONB;
  v_date INT; v_old INT; v_edge INT; v_thr INT; v_dd INT; v_rec INT; v_armed INT; v_prob INT;
  v_next_thr TIMESTAMPTZ := now() + interval '5 hours';
  r agent.monitor_triggers%ROWTYPE;
BEGIN
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, next_check_at, status, fired_at)
  VALUES ('__test__', 'date fresh', 'date', core.fn_today(), interval '1 day', now() + interval '1 day', 'fired', now())
  RETURNING id INTO v_date;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, next_check_at, status, fired_at)
  VALUES ('__test__', 'date too old', 'date', core.fn_today() - 4, interval '1 day', now() + interval '1 day', 'fired', now())
  RETURNING id INTO v_old;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, next_check_at, status, fired_at)
  VALUES ('__test__', 'date at limit', 'date', core.fn_today() - 3, interval '1 day', now() + interval '1 day', 'fired', now())
  RETURNING id INTO v_edge;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
      threshold_value, expected_unit, check_interval, next_check_at, status, fired_at, last_value)
  VALUES ('__test__', 'threshold', 'threshold', 'web_search', '{"prompt":"x"}', 'gte', 10, 'USD', interval '1 day',
      v_next_thr, 'fired', now(), 12)
  RETURNING id INTO v_thr;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, drawdown_pct,
      expected_unit, check_interval, next_check_at, status, fired_at, last_value, reference_value)
  VALUES ('__test__', 'drawdown', 'drawdown', 'web_search', '{"prompt":"x"}', 10, 'USD', interval '1 day',
      v_next_thr, 'fired', now(), 80, 100)
  RETURNING id INTO v_dd;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, next_check_at, status)
  VALUES ('__test__', 'already armed', 'date', core.fn_today() + 10, interval '1 day', v_next_thr, 'armed')
  RETURNING id INTO v_armed;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, expected_unit,
      check_interval, next_check_at, status, fail_streak)
  VALUES ('__test__', 'problem', 'recurring_info', 'web_search', '{"prompt":"x"}', 'USD', interval '1 day', v_next_thr, 'armed', 3)
  RETURNING id INTO v_prob;

  v := agent.fn_monitor_reset_unsent(jsonb_build_object(
    'trigger_ids', jsonb_build_array(v_date, v_old, v_edge, v_thr, v_dd, v_armed),
    'problem_ids', jsonb_build_array(v_prob)));

  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL: ok %', v; END IF;
  IF jsonb_array_length(v->'reset') <> 4 THEN RAISE EXCEPTION 'FAIL: reset len %', v; END IF;
  IF jsonb_array_length(v->'problems_pending') <> 1 THEN RAISE EXCEPTION 'FAIL: problems_pending %', v; END IF;
  IF jsonb_array_length(v->'gave_up') <> 1 OR v->'gave_up'->0->>'label' <> 'date too old'
    THEN RAISE EXCEPTION 'FAIL: gave_up %', v; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_date;
  IF r.status <> 'armed' OR r.fired_at IS NOT NULL OR r.next_check_at > now() THEN RAISE EXCEPTION 'FAIL: date reset %', r; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_edge;
  IF r.status <> 'armed' THEN RAISE EXCEPTION 'FAIL: Grenze unsent_retry_days muss noch zuruecksetzen'; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_old;
  IF r.status <> 'fired' OR r.fired_at IS NULL THEN RAISE EXCEPTION 'FAIL: zu alter Termin bleibt fired'; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_thr;
  IF r.status <> 'armed' OR r.fired_at IS NOT NULL OR r.next_check_at <> v_next_thr OR r.last_value <> 12
    THEN RAISE EXCEPTION 'FAIL: threshold reset %', r; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_dd;
  IF r.status <> 'armed' OR r.reference_value <> 100 OR r.last_value <> 80 OR r.next_check_at <> v_next_thr
    THEN RAISE EXCEPTION 'FAIL: Ratchet unberuehrt %', r; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_armed;
  IF r.next_check_at <> v_next_thr THEN RAISE EXCEPTION 'FAIL: armed bleibt unberuehrt'; END IF;

  SELECT * INTO r FROM agent.monitor_triggers WHERE id = v_prob;
  IF r.problem_pending_at IS NULL THEN RAISE EXCEPTION 'FAIL: Problem nicht vorgemerkt'; END IF;

  -- Leere/fehlende Listen: kein Fehler, nichts passiert
  v := agent.fn_monitor_reset_unsent('{}'::jsonb);
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(v->'reset') <> 0 THEN RAISE EXCEPTION 'FAIL: leer %', v; END IF;

  -- Config wird zur Laufzeit gelesen
  UPDATE core.config SET value = '5' WHERE category = 'monitor' AND key = 'unsent_retry_days';
  v := agent.fn_monitor_reset_unsent(jsonb_build_object('trigger_ids', jsonb_build_array(v_old)));
  IF jsonb_array_length(v->'reset') <> 1 THEN RAISE EXCEPTION 'FAIL: Config nicht beachtet %', v; END IF;
END $$;
ROLLBACK;
