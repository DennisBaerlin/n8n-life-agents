-- tests/db/core/test_fn_monitor_evaluate.sql
-- Testet fn_monitor_evaluate: die EINE atomare Auswertungs-Function des Heartbeat-Crons.
-- Vertrag (Eingabe jsonb): { now: timestamptz (Test-Injektion), observations: [{trigger_id,
--   ok, value, unit, as_of, source_url, reason}] (nur web_search — sql/Paket-Methoden beschafft die fn
--   selbst), fail_alert_streak (Test-Override; Default aus core.config monitor.* bzw. 3) }.
--   Phase B: Paket-Methode via Registry (Test-Methode zz_test, Stub-fns) + PARKEN bei inaktivem Paket.
-- Rueckgabe: { ok, checked, fired:[...], info:[...], problems:[...] }.
-- Verhalten: FOR UPDATE + Status-Recheck (TOCTOU); Validierungs-Kaskade; Observation-Log
--   IMMER; threshold/drawdown/date latchen One-Shot (armed->fired); date: Vorwarnung als
--   NICHT-latchende Info, Latch erst am due_date; recurring_info latcht NIE; dirty ->
--   fail_streak++ / last_value+Ratchet unberuehrt; Advance next_check_at bei Erfolg UND
--   Fehlschlag; "heute" = core.fn_today(now) in der Sitzungs-Zeitzone (Mitternachts-Test).
BEGIN;
-- Roter Faden: die Bestandsfaelle laufen mit fester Uhr (07:10) -> Erinnerungs-Fenster hier auf den ganzen Tag;
-- das Fenster-Verhalten selbst prueft test_fn_monitor_evaluate (Block "Erinnerungs-Fenster").
INSERT INTO core.config (package, category, key, value) VALUES
  ('core', 'general', 'reminders_from', '0'), ('core', 'general', 'reminders_until', '24')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;

-- Tests laufen linear; "wieder faellig machen" = UPDATE next_check_at zwischen den Calls.
DO $$
DECLARE
  v_now    TIMESTAMPTZ := '2026-06-10 07:10+02'::timestamptz;
  v_today  CONSTANT DATE := '2026-06-10';
  v        JSONB;
  v_id_thr INT; v_id_dd INT; v_id_date INT; v_id_rec INT; v_id_sql INT; v_id_fx INT;
  v_row    agent.monitor_triggers%ROWTYPE;
  v_count  INT;
BEGIN

  -- ==========================================================
  -- TEST 1: threshold gte — Fire + Latch + kein Re-Fire
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, min_plausible, max_plausible, check_interval,
     next_check_at, action_note)
  VALUES ('__test__', 'gold over 4000', 'threshold', 'web_search',
          '{"prompt": "gold price usd per troy ounce"}', 'gte',
          4000, 'USD/oz', 1000, 10000, INTERVAL '1 day', v_now - INTERVAL '1 hour',
          'Rebalancing pruefen')
  RETURNING id INTO v_id_thr;

  -- unter der Schwelle: kein Fire, last_value gepflegt, Advance
  v := agent.fn_monitor_evaluate(jsonb_build_object(
    'now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', true, 'value', 3900, 'unit', 'USD/oz',
      'as_of', '2026-06-09', 'source_url', 'https://example.com'))));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [thr unter Schwelle]: fired nicht leer, got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_thr;
  IF v_row.last_value IS DISTINCT FROM 3900 OR v_row.status IS DISTINCT FROM 'armed'
     OR v_row.next_check_at <= v_now OR v_row.last_checked_at IS DISTINCT FROM v_now THEN
    RAISE EXCEPTION 'FAIL evaluate [thr unter Schwelle]: Post-State falsch (last_value=%, status=%, next=%)',
      v_row.last_value, v_row.status, v_row.next_check_at;
  END IF;
  RAISE NOTICE 'PASS evaluate [threshold unter Schwelle: kein Fire, State gepflegt]';

  -- ueber der Schwelle: Fire + Latch
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object(
    'now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', true, 'value', 4050, 'unit', 'USD/oz',
      'as_of', '2026-06-10', 'source_url', 'https://example.com'))));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 1
     OR v->'fired'->0->>'label' IS DISTINCT FROM 'gold over 4000'
     OR (v->'fired'->0->>'value')::numeric IS DISTINCT FROM 4050
     OR v->'fired'->0->>'action_note' IS DISTINCT FROM 'Rebalancing pruefen' THEN
    RAISE EXCEPTION 'FAIL evaluate [thr fire]: got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_thr;
  IF v_row.status IS DISTINCT FROM 'fired' OR v_row.fired_at IS NULL THEN
    RAISE EXCEPTION 'FAIL evaluate [thr latch]: status=%, fired_at=%', v_row.status, v_row.fired_at;
  END IF;
  RAISE NOTICE 'PASS evaluate [threshold gte: Fire + Latch]';

  -- One-Shot: gefeuerter Trigger ist nie wieder due (auch mit past next_check_at)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object(
    'now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', true, 'value', 4100, 'unit', 'USD/oz'))));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [one-shot]: gefeuerter Trigger feuerte erneut, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [One-Shot: kein Re-Fire]';

  -- Re-Arm-Epoche (direkter Status-Reset wie set-Tool) -> feuert wieder
  UPDATE agent.monitor_triggers
     SET status = 'armed', fired_at = NULL, next_check_at = v_now - INTERVAL '1 hour'
   WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object(
    'now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', true, 'value', 4100, 'unit', 'USD/oz'))));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [re-arm]: erwartet erneutes Fire, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [Re-Arm -> feuert erneut]';

  -- ==========================================================
  -- TEST 2: threshold lte (beide Richtungen abgedeckt)
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at)
  VALUES ('__test__', 'krw under 1300', 'threshold', 'web_search',
          '{"prompt": "eur krw"}', 'lte', 1300, 'KRW', INTERVAL '1 day',
          v_now - INTERVAL '1 hour')
  RETURNING id INTO v_id_fx;
  v := agent.fn_monitor_evaluate(jsonb_build_object(
    'now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_fx, 'ok', true, 'value', 1280, 'unit', 'KRW'))));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [lte fire]: got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [threshold lte feuert]';

  -- ==========================================================
  -- TEST 3: drawdown — Ratchet steigt, faellt nie, ignoriert dirty, feuert bei pct
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, drawdown_pct,
     expected_unit, min_plausible, max_plausible, check_interval, next_check_at)
  VALUES ('__test__', 'msci crash 20', 'drawdown', 'web_search',
          '{"prompt": "msci world etf eur"}', 20, 'EUR', 10, 1000, INTERVAL '1 day',
          v_now - INTERVAL '1 hour')
  RETURNING id INTO v_id_dd;

  -- Beobachtung 1: 100 -> Ratchet-Seed, kein Fire (dd=0)
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_dd, 'ok', true, 'value', 100, 'unit', 'EUR'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_dd;
  IF v_row.reference_value IS DISTINCT FROM 100 OR jsonb_array_length(v->'fired') <> 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [dd seed]: ref=%, got %', v_row.reference_value, v;
  END IF;
  -- Beobachtung 2: 110 -> Ratchet steigt
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_dd;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_dd, 'ok', true, 'value', 110, 'unit', 'EUR'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_dd;
  IF v_row.reference_value IS DISTINCT FROM 110 THEN
    RAISE EXCEPTION 'FAIL evaluate [dd ratchet up]: ref=%', v_row.reference_value;
  END IF;
  -- Beobachtung 3: 90 -> dd 18.2%% < 20 -> KEIN Fire, Ratchet bleibt 110
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_dd;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_dd, 'ok', true, 'value', 90, 'unit', 'EUR'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_dd;
  IF jsonb_array_length(v->'fired') <> 0 OR v_row.reference_value IS DISTINCT FROM 110 THEN
    RAISE EXCEPTION 'FAIL evaluate [dd -18%%]: fired/%/ref=%', v, v_row.reference_value;
  END IF;
  -- dirty Beobachtung (out of bounds 5000) -> Ratchet UNBERUEHRT (Peak-Poisoning-Schutz)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_dd;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_dd, 'ok', true, 'value', 5000, 'unit', 'EUR'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_dd;
  IF v_row.reference_value IS DISTINCT FROM 110 OR v_row.fail_streak IS DISTINCT FROM 1
     OR v_row.last_value IS DISTINCT FROM 90 THEN
    RAISE EXCEPTION 'FAIL evaluate [dd poisoning]: ref=%, streak=%, last=%',
      v_row.reference_value, v_row.fail_streak, v_row.last_value;
  END IF;
  -- Beobachtung 4: 87 -> dd 20.9%% >= 20 -> Fire (+ Streak-Reset durch sauberen Wert)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_dd;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_dd, 'ok', true, 'value', 87, 'unit', 'EUR'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_dd;
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 1 OR v_row.status IS DISTINCT FROM 'fired'
     OR (v->'fired'->0->>'drawdown_observed')::numeric < 20
     OR v_row.fail_streak IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [dd fire]: got % / status=% / streak=%', v, v_row.status, v_row.fail_streak;
  END IF;
  RAISE NOTICE 'PASS evaluate [drawdown: Seed/Ratchet/Poisoning-Schutz/Fire bei 20%%]';

  -- ==========================================================
  -- TEST 4: date — Vorwarnung als Info (kein Latch), Latch erst am due_date
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, due_date, warn_days_before,
     check_interval, next_check_at, action_note)
  VALUES ('__test__', 'zinsbindung ende', 'date', 'none', v_today + 5, 7,
          INTERVAL '1 day', v_now - INTERVAL '1 hour', 'Anschlussfinanzierung klaeren')
  RETURNING id INTO v_id_date;

  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [date warn]: Vorwarnung hat gelatcht, got %', v;
  END IF;
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'info') e
   WHERE e->>'label' = 'zinsbindung ende' AND e->>'kind' = 'date_warning'
     AND (e->>'days_left')::int = 5;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [date warn]: keine date_warning-Info (days_left=5), got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_date;
  IF v_row.status IS DISTINCT FROM 'armed' THEN
    RAISE EXCEPTION 'FAIL evaluate [date warn]: Status nicht mehr armed: %', v_row.status;
  END IF;
  RAISE NOTICE 'PASS evaluate [date: Vorwarnung ohne Latch, days_left korrekt]';

  -- am due_date: Fire + Latch
  UPDATE agent.monitor_triggers
     SET due_date = v_today, next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_date;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'fired') e
   WHERE e->>'label' = 'zinsbindung ende';
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_date;
  IF v_count IS DISTINCT FROM 1 OR v_row.status IS DISTINCT FROM 'fired' THEN
    RAISE EXCEPTION 'FAIL evaluate [date fire]: count=%, status=%', v_count, v_row.status;
  END IF;
  RAISE NOTICE 'PASS evaluate [date: Latch am due_date]';

  -- Mitternacht: "heute" = Kalendertag der Sitzungs-Zeitzone (Installer setzt sie auf die Haushalts-Zeitzone).
  -- 22:30 UTC am 10.06. ist in Berlin (+2) schon der 11. -> ein am 11. faelliger Trigger feuert, in UTC noch nicht.
  DECLARE
    v_tz   CONSTANT TEXT := current_setting('TimeZone');
    v_mid  CONSTANT TIMESTAMPTZ := '2026-06-10 22:30+00';
    v_id_m INT;
  BEGIN
    INSERT INTO agent.monitor_triggers
      (domain, label, trigger_type, acquisition_method, due_date, warn_days_before,
       check_interval, next_check_at, action_note)
    VALUES ('__test__', 'mitternacht', 'date', 'none', DATE '2026-06-11', 0,
            INTERVAL '1 day', v_mid - INTERVAL '1 hour', 'Test')
    RETURNING id INTO v_id_m;
    PERFORM set_config('TimeZone', 'UTC', true);
    v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_mid));
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'fired') e WHERE e->>'label' = 'mitternacht') THEN
      RAISE EXCEPTION 'FAIL evaluate [Mitternacht UTC]: schon am 10. gefeuert, got %', v;
    END IF;
    UPDATE agent.monitor_triggers SET next_check_at = v_mid - INTERVAL '1 hour' WHERE id = v_id_m;
    PERFORM set_config('TimeZone', 'Europe/Berlin', true);
    v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_mid));
    PERFORM set_config('TimeZone', v_tz, true);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'fired') e WHERE e->>'label' = 'mitternacht') THEN
      RAISE EXCEPTION 'FAIL evaluate [Mitternacht Berlin]: am 11. (Berlin) nicht gefeuert, got %', v;
    END IF;
  END;
  RAISE NOTICE 'PASS evaluate [date: "heute" folgt der Sitzungs-Zeitzone ueber Mitternacht]';

  -- ausserhalb des Warn-Fensters: weder Fire noch Info
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, due_date, warn_days_before,
     check_interval, next_check_at)
  VALUES ('__test__', 'far future date', 'date', 'none', v_today + 30, 7,
          INTERVAL '1 day', v_now - INTERVAL '1 hour');
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'info') e
   WHERE e->>'label' = 'far future date';
  IF v_count IS DISTINCT FROM 0 OR jsonb_array_length(v->'fired') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [date quiet]: got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [date: ausserhalb Warn-Fenster still]';

  -- ==========================================================
  -- TEST 5: recurring_info — latcht NIE, feuert jede faellige Runde; sql-Beschaffung
  -- laeuft in der fn unter core_ro (current_user-Echo beweist den Rollen-Switch; B3)
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec,
     expected_unit, check_interval, next_check_at)
  VALUES ('__test__', 'role echo', 'recurring_info', 'sql',
          jsonb_build_object('query', 'SELECT CASE WHEN current_user = ''core_ro_eval'' THEN 1 ELSE 0 END'),
          'flag', INTERVAL '1 day', v_now - INTERVAL '1 hour')
  RETURNING id INTO v_id_sql;

  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'info') e
   WHERE e->>'label' = 'role echo' AND (e->>'value')::numeric = 1;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [recurring sql]: kein Info-Eintrag mit value=1 (core_ro), got %', v;
  END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_sql;
  IF v_row.status IS DISTINCT FROM 'armed' THEN
    RAISE EXCEPTION 'FAIL evaluate [recurring latch]: recurring_info hat gelatcht: %', v_row.status;
  END IF;
  -- zweite Runde: feuert WIEDER (nie Latch)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_sql;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'info') e WHERE e->>'label' = 'role echo';
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [recurring repeat]: zweite Runde ohne Info, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [recurring_info: sql unter core_ro, latcht nie]';

  -- ==========================================================
  -- TEST 6 (Phase B): Paket-Methode via Registry — feuert mit dem Wert der acquire_fn; Paket inaktiv ->
  -- GEPARKT (nicht geprueft, kein fail_streak, next_check_at unberuehrt); Paket wieder aktiv -> laeuft an
  -- ==========================================================
  CREATE SCHEMA zz_pkg;
  CREATE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', true, 'spec', p->'params', 'display', 'x') $f$;
  CREATE FUNCTION zz_pkg.fn_acquire(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', true, 'value', (p->'spec'->>'v')::numeric, 'as_of', p->>'as_of') $f$;
  INSERT INTO core.package_registry (package, status) VALUES ('zz_pkg', 'active');
  INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
  VALUES ('zz_test', 'zz_pkg.fn_acquire', 'zz_pkg.fn_validate', 'zz_pkg');

  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, check_interval, next_check_at)
  VALUES ('__test__', 'zz over 1400', 'threshold', 'zz_test',
          '{"v": 1450}', 'gte', 1400, INTERVAL '1 day', v_now - INTERVAL '1 hour')
  RETURNING id INTO v_id_fx;

  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'fired') e
   WHERE e->>'label' = 'zz over 1400' AND (e->>'value')::numeric = 1450;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [pkg method fire]: kein Fire mit value=1450, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [Paket-Methode feuert mit dem Wert der acquire_fn]';

  -- Paket inaktiv: Re-Arm, dann geparkt
  UPDATE agent.monitor_triggers
     SET status = 'armed', fired_at = NULL, next_check_at = v_now - INTERVAL '1 hour'
   WHERE id = v_id_fx;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'zz_pkg';
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_fx;
  IF jsonb_array_length(v->'fired') IS DISTINCT FROM 0 OR jsonb_array_length(v->'problems') IS DISTINCT FROM 0
     OR v_row.fail_streak IS DISTINCT FROM 0 OR v_row.next_check_at IS DISTINCT FROM v_now - INTERVAL '1 hour' THEN
    RAISE EXCEPTION 'FAIL evaluate [pkg inactive park]: v=% streak=% next=%', v, v_row.fail_streak, v_row.next_check_at;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.fn_monitor_due(v_now) d WHERE d.id = v_id_fx) THEN
    RAISE EXCEPTION 'FAIL evaluate [pkg inactive park]: fn_monitor_due listet den geparkten Trigger';
  END IF;
  RAISE NOTICE 'PASS evaluate [Paket inaktiv -> Trigger geparkt (kein Fehlerpfad, nicht faellig)]';

  UPDATE core.package_registry SET status = 'active' WHERE package = 'zz_pkg';
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'fired') e WHERE e->>'label' = 'zz over 1400';
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [pkg reactivated]: Trigger laeuft nicht wieder an, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [Paket wieder aktiv -> Trigger laeuft an]';

  -- ==========================================================
  -- TEST 7: fail_streak-Alarm exakt bei Config-Wert (Override 2) + Vielfachen + Reset
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at)
  VALUES ('__test__', 'flaky source', 'threshold', 'web_search',
          '{"prompt": "x"}', 'gte', 100, 'USD', INTERVAL '1 day', v_now - INTERVAL '1 hour')
  RETURNING id INTO v_id_thr;

  -- Fehlschlag 1: noch KEIN Problem-Alarm (Schwelle 2)
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now, 'fail_alert_streak', 2,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', false, 'reason', 'cannot determine'))));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'problems') e
   WHERE e->>'label' = 'flaky source';
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_thr;
  IF v_count IS DISTINCT FROM 0 OR v_row.fail_streak IS DISTINCT FROM 1
     OR v_row.next_check_at <= v_now THEN
    RAISE EXCEPTION 'FAIL evaluate [streak 1]: problems=%/streak=%/next=%',
      v_count, v_row.fail_streak, v_row.next_check_at;
  END IF;
  -- Fehlschlag 2: Problem-Alarm (erreicht Schwelle), Advance auch im Fehlerpfad
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now, 'fail_alert_streak', 2,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', false, 'reason', 'cannot determine'))));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'problems') e
   WHERE e->>'label' = 'flaky source' AND (e->>'fail_streak')::int = 2
     AND e->>'first_fail' IS NOT NULL;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [streak 2]: kein Problem-Eintrag mit first_fail, got %', v;
  END IF;
  -- Fehlschlag 3: KEIN Alarm (zwischen Vielfachen)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now, 'fail_alert_streak', 2,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', false, 'reason', 'cannot determine'))));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'problems') e
   WHERE e->>'label' = 'flaky source';
  IF v_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [streak 3]: Alarm zwischen Vielfachen, got %', v;
  END IF;
  -- Fehlschlag 4: Alarm (Vielfaches von 2)
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now, 'fail_alert_streak', 2,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', false, 'reason', 'cannot determine'))));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'problems') e
   WHERE e->>'label' = 'flaky source' AND (e->>'fail_streak')::int = 4;
  IF v_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL evaluate [streak 4]: kein Alarm am Vielfachen, got %', v;
  END IF;
  -- Erfolg: Streak-Reset + last_value
  UPDATE agent.monitor_triggers SET next_check_at = v_now - INTERVAL '1 hour' WHERE id = v_id_thr;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now, 'fail_alert_streak', 2,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_thr, 'ok', true, 'value', 50, 'unit', 'USD'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_thr;
  IF v_row.fail_streak IS DISTINCT FROM 0 OR v_row.last_value IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL evaluate [streak reset]: streak=%/last=%', v_row.fail_streak, v_row.last_value;
  END IF;
  RAISE NOTICE 'PASS evaluate [fail_streak: Alarm bei Schwelle+Vielfachen, Reset bei Erfolg]';

  -- Observation-Log: beide Pfade geschrieben (5 Fehlschlaege/Erfolge dieses Triggers)
  SELECT COUNT(*) INTO v_count FROM agent.monitor_observations WHERE trigger_id = v_id_thr;
  IF v_count IS DISTINCT FROM 5 THEN
    RAISE EXCEPTION 'FAIL evaluate [observation log]: erwartet 5 Zeilen, got %', v_count;
  END IF;
  SELECT COUNT(*) INTO v_count FROM agent.monitor_observations
   WHERE trigger_id = v_id_thr AND ok = false;
  IF v_count IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL evaluate [observation log]: erwartet 4 dirty Zeilen, got %', v_count;
  END IF;
  RAISE NOTICE 'PASS evaluate [Observation-Log beide Pfade]';

  -- ==========================================================
  -- TEST 8: TOCTOU — disabled Trigger wird trotz passender Observation ignoriert
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at, status)
  VALUES ('__test__', 'disabled thr', 'threshold', 'web_search',
          '{"prompt": "x"}', 'gte', 100, 'USD', INTERVAL '1 day',
          v_now - INTERVAL '1 hour', 'disabled')
  RETURNING id INTO v_id_rec;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', jsonb_build_array(jsonb_build_object(
      'trigger_id', v_id_rec, 'ok', true, 'value', 500, 'unit', 'USD'))));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id_rec;
  IF v_row.status IS DISTINCT FROM 'disabled' OR jsonb_array_length(v->'fired') <> 0 THEN
    RAISE EXCEPTION 'FAIL evaluate [TOCTOU disabled]: got % / status=%', v, v_row.status;
  END IF;
  RAISE NOTICE 'PASS evaluate [TOCTOU: disabled ignoriert]';

  -- ==========================================================
  -- TEST 9: mehrere Fires in EINEM Lauf (eine kombinierte Message)
  -- ==========================================================
  INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at)
  VALUES
    ('__test__', 'multi a', 'threshold', 'web_search', '{"prompt": "a"}', 'gte', 10, 'X',
     INTERVAL '1 day', v_now - INTERVAL '1 hour'),
    ('__test__', 'multi b', 'threshold', 'web_search', '{"prompt": "b"}', 'gte', 10, 'X',
     INTERVAL '1 day', v_now - INTERVAL '1 hour');
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_now,
    'observations', (SELECT jsonb_agg(jsonb_build_object(
        'trigger_id', t.id, 'ok', true, 'value', 99, 'unit', 'X'))
      FROM agent.monitor_triggers t
      WHERE t.domain='__test__' AND t.label IN ('multi a','multi b'))));
  SELECT COUNT(*) INTO v_count FROM jsonb_array_elements(v->'fired') e
   WHERE e->>'label' IN ('multi a','multi b');
  IF v_count IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL evaluate [multi-fire]: erwartet 2 Fires, got %', v;
  END IF;
  RAISE NOTICE 'PASS evaluate [mehrere Fires in einem Lauf]';

END $$;

-- ==========================================================
-- Roter Faden: Erinnerungs-Fenster (10..20 Uhr, Haushalts-Zeitzone). Datums-Vorwarnung nachts NICHT faellig (bleibt
-- faellig -> 10:10 kommt sie); Wert-Waechter feuert nachts sofort; Problembericht nachts vorgemerkt, im Fenster
-- nachgereicht; behobener Trigger -> Vormerkung still weg.
-- ==========================================================
DO $$
DECLARE
  v_night CONSTANT TIMESTAMPTZ := '2026-06-10 03:10+02'::timestamptz;
  v_day   CONSTANT TIMESTAMPTZ := '2026-06-10 10:10+02'::timestamptz;
  v       JSONB;
  v_date  INT; v_thr INT; v_fl INT;
BEGIN
  SET LOCAL TimeZone = 'Europe/Berlin';
  UPDATE core.config SET value = '10' WHERE category = 'general' AND key = 'reminders_from';
  UPDATE core.config SET value = '20' WHERE category = 'general' AND key = 'reminders_until';
  UPDATE agent.monitor_triggers SET status = 'disabled' WHERE status = 'armed';

  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, warn_days_before,
     check_interval, next_check_at)
  VALUES ('__test__', 'fenster datum', 'date', 'none', DATE '2026-06-15', 7, INTERVAL '1 day', v_night - INTERVAL '1 hour')
  RETURNING id INTO v_date;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at)
  VALUES ('__test__', 'fenster wert', 'threshold', 'web_search', '{"prompt": "w"}', 'gte', 10, 'X',
          INTERVAL '12 hours', v_night - INTERVAL '1 hour')
  RETURNING id INTO v_thr;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
     threshold_value, expected_unit, check_interval, next_check_at)
  VALUES ('__test__', 'fenster kaputt', 'threshold', 'web_search', '{"prompt": "k"}', 'gte', 10, 'X',
          INTERVAL '1 day', v_night - INTERVAL '1 hour')
  RETURNING id INTO v_fl;

  -- Nacht: Wert-Waechter feuert, Datum nicht faellig, Problem (Schwelle 1) nur vorgemerkt
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_night, 'fail_alert_streak', 1,
    'observations', jsonb_build_array(
      jsonb_build_object('trigger_id', v_thr, 'ok', true, 'value', 99, 'unit', 'X'),
      jsonb_build_object('trigger_id', v_fl, 'ok', false, 'reason', 'kaputt'))));
  IF jsonb_array_length(v->'fired') <> 1 OR jsonb_array_length(v->'info') <> 0 OR jsonb_array_length(v->'problems') <> 0 THEN
    RAISE EXCEPTION 'FAIL fenster [Nacht: 1 fired, 0 info, 0 problems erwartet]: %', v; END IF;
  IF (SELECT problem_pending_at FROM agent.monitor_triggers WHERE id = v_fl) IS NULL THEN
    RAISE EXCEPTION 'FAIL fenster [Nacht: Problem nicht vorgemerkt]'; END IF;
  IF (SELECT count(*) FROM agent.fn_monitor_due(v_night) d WHERE d.id = v_date) <> 0 THEN
    RAISE EXCEPTION 'FAIL fenster [fn_monitor_due Nacht: Datum darf nicht faellig sein]'; END IF;

  -- Tag: Datums-Vorwarnung kommt, vorgemerktes Problem wird nachgereicht (Trigger scheitert weiter, nicht faellig)
  IF (SELECT count(*) FROM agent.fn_monitor_due(v_day) d WHERE d.id = v_date) <> 1 THEN
    RAISE EXCEPTION 'FAIL fenster [fn_monitor_due Tag: Datum faellig]'; END IF;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_day, 'fail_alert_streak', 1));
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'info') e WHERE (e->>'id')::int = v_date AND e->>'kind' = 'date_warning') THEN
    RAISE EXCEPTION 'FAIL fenster [Tag: Datums-Vorwarnung erwartet]: %', v; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v->'problems') e WHERE (e->>'id')::int = v_fl AND e->>'reason' = 'kaputt') THEN
    RAISE EXCEPTION 'FAIL fenster [Tag: vorgemerktes Problem nachgereicht]: %', v; END IF;
  IF (SELECT problem_pending_at FROM agent.monitor_triggers WHERE id = v_fl) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fenster [Vormerkung nach Nachreichen geleert]'; END IF;

  -- behoben vor dem Fenster -> Vormerkung still weg
  UPDATE agent.monitor_triggers SET problem_pending_at = v_night, fail_streak = 0 WHERE id = v_fl;
  v := agent.fn_monitor_evaluate(jsonb_build_object('now', v_day + INTERVAL '1 hour', 'fail_alert_streak', 1));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'problems') e WHERE (e->>'id')::int = v_fl) THEN
    RAISE EXCEPTION 'FAIL fenster [behoben -> kein Bericht]: %', v; END IF;
  RAISE NOTICE 'PASS evaluate [Erinnerungs-Fenster: Datum/Problem halten statt verwerfen, Wert sofort]';
END $$;

ROLLBACK;
