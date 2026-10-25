-- tests/db/core/test_fn_create_monitor_trigger.sql
-- Testet fn_create_monitor_trigger: HITL-gegatetes Anlegen eines Monitor-Triggers.
-- Vertrag: Eingabe jsonb (domain default 'general', label, trigger_type, acquisition_method,
--   acquisition_prompt|acquisition_sql|acquisition_params (Paket-Methode), comparator, threshold_value,
--   drawdown_pct, reference_value (optionaler Seed), due_date, warn_days_before,
--   expected_unit, min/max_plausible, max_jump_pct, check_interval (String), action_note,
--   probe_observation (optional: validierte Probe -> erste Observation + Ratchet-Seed)).
--   Erfolg -> {ok:true, trigger_id, status:'armed', next_check_at, check_interval, armed_count}.
--   Korrigierbar -> {ok:false, reason} OHNE Write (alle CHECKs als freundliche Guards gespiegelt).
BEGIN;

DO $$
DECLARE
  v      JSONB;
  v_id   INT;
  v_row  agent.monitor_triggers%ROWTYPE;
  v_cnt  INT;
BEGIN

  -- TEST 1: threshold/web happy path
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Gold over 4000',
    'trigger_type', 'threshold', 'acquisition_method', 'web_search',
    'acquisition_prompt', 'Current spot price of gold (XAU) in USD per troy ounce.',
    'comparator', 'gte', 'threshold_value', 4000,
    'expected_unit', 'USD/oz', 'min_plausible', 1000, 'max_plausible', 10000,
    'check_interval', '1 day', 'action_note', 'Rebalancing pruefen'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'trigger_id') IS NULL
     OR v->>'status' IS DISTINCT FROM 'armed'
     OR (v->>'armed_count')::int < 1 THEN
    RAISE EXCEPTION 'FAIL create [happy web]: got %', v;
  END IF;
  v_id := (v->>'trigger_id')::int;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.acquisition_spec->>'prompt' NOT LIKE '%troy ounce%'
     OR v_row.check_interval IS DISTINCT FROM INTERVAL '1 day' THEN
    RAISE EXCEPTION 'FAIL create [happy web]: Zeile falsch (spec=%, interval=%)',
      v_row.acquisition_spec, v_row.check_interval;
  END IF;
  RAISE NOTICE 'PASS create [threshold/web happy, trigger_id=%]', v_id;

  -- TEST 2: Dublette (case-insensitiv) -> {ok:false}, kein zweiter Write
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'GOLD OVER 4000',
    'trigger_type', 'threshold', 'acquisition_method', 'web_search',
    'acquisition_prompt', 'x', 'comparator', 'gte', 'threshold_value', 1,
    'expected_unit', 'USD', 'check_interval', '1 day'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%exist%' THEN
    RAISE EXCEPTION 'FAIL create [duplicate]: got %', v;
  END IF;
  RAISE NOTICE 'PASS create [Dublette case-insensitiv abgelehnt]';

  -- TEST 3: date happy path (acquisition none)
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Zinsbindung Ende',
    'trigger_type', 'date', 'due_date', '2027-09-30', 'warn_days_before', 60,
    'check_interval', '7 days', 'action_note', 'Anschlussfinanzierung'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL create [date]: got %', v;
  END IF;
  RAISE NOTICE 'PASS create [date happy]';

  -- TEST 3b (WP3): relative Faelligkeit rechnet die DB; Vergangenheit/Freitext -> {ok:false}
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Rente pruefen relativ', 'trigger_type', 'date', 'due_date', '+6 months', 'check_interval', '7 days'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true
     OR (v->>'due_date')::date IS DISTINCT FROM (core.fn_today() + interval '6 months')::date
     OR (SELECT due_date FROM agent.monitor_triggers WHERE id = (v->>'trigger_id')::int)
        IS DISTINCT FROM (core.fn_today() + interval '6 months')::date THEN
    RAISE EXCEPTION 'FAIL create [date relativ +6 months]: got %', v;
  END IF;
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Vergangen', 'trigger_type', 'date', 'due_date', '-1 day', 'check_interval', '7 days'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%past%' THEN
    RAISE EXCEPTION 'FAIL create [date Vergangenheit]: got %', v;
  END IF;
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Freitext', 'trigger_type', 'date', 'due_date', 'in sechs Monaten', 'check_interval', '7 days'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%relative%' THEN
    RAISE EXCEPTION 'FAIL create [date Freitext]: got %', v;
  END IF;
  RAISE NOTICE 'PASS create [date relativ von der DB gerechnet, Vergangenheit/Freitext abgelehnt]';

  -- TEST 4: recurring_info/sql happy + Shape-Validierung
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Monatlicher Kontostand',
    'trigger_type', 'recurring_info', 'acquisition_method', 'sql',
    'acquisition_sql', 'SELECT COALESCE(SUM(balance), 0) FROM finance.account_balances',
    'expected_unit', 'EUR', 'check_interval', '1 month'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL create [recurring sql]: got %', v;
  END IF;
  RAISE NOTICE 'PASS create [recurring_info/sql happy]';

  -- TEST 5: drawdown mit probe_observation -> Ratchet-Seed + erste Observation + last_value
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'MSCI Crash 20',
    'trigger_type', 'drawdown', 'acquisition_method', 'web_search',
    'acquisition_prompt', 'iShares Core MSCI World close in EUR',
    'drawdown_pct', 20, 'expected_unit', 'EUR', 'min_plausible', 10, 'max_plausible', 1000,
    'check_interval', '1 day',
    'probe_observation', jsonb_build_object('ok', true, 'value', 112.34, 'unit', 'EUR',
      'as_of', '2026-06-09', 'source_url', 'https://example.com')
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL create [dd probe]: got %', v;
  END IF;
  v_id := (v->>'trigger_id')::int;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = v_id;
  IF v_row.reference_value IS DISTINCT FROM 112.34 OR v_row.last_value IS DISTINCT FROM 112.34 THEN
    RAISE EXCEPTION 'FAIL create [dd probe]: Seed fehlt (ref=%, last=%)',
      v_row.reference_value, v_row.last_value;
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM agent.monitor_observations WHERE trigger_id = v_id AND ok = true;
  IF v_cnt IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL create [dd probe]: Probe nicht als Observation geloggt';
  END IF;
  RAISE NOTICE 'PASS create [drawdown: Probe-Seed (Ratchet/last_value/Observation)]';

  -- TEST 6: Guards — jede Verletzung freundlich {ok:false}, KEIN Write
  -- leeres Label
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', '  ', 'trigger_type', 'date',
    'due_date', '2027-01-01', 'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL create [empty label]: got %', v; END IF;
  -- threshold ohne comparator
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g1', 'trigger_type', 'threshold',
    'acquisition_method', 'web_search', 'acquisition_prompt', 'x',
    'threshold_value', 5, 'expected_unit', 'X', 'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL create [no comparator]: got %', v; END IF;
  -- drawdown_pct >= 100
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g2', 'trigger_type', 'drawdown',
    'acquisition_method', 'web_search', 'acquisition_prompt', 'x',
    'drawdown_pct', 150, 'expected_unit', 'X', 'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL create [dd>=100]: got %', v; END IF;
  -- Web-Cadence unter 12h (Rate-Limit, Owner-Vorgabe)
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g3', 'trigger_type', 'threshold',
    'acquisition_method', 'web_search', 'acquisition_prompt', 'x',
    'comparator', 'gte', 'threshold_value', 5, 'expected_unit', 'X',
    'check_interval', '6 hours'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%12%' THEN
    RAISE EXCEPTION 'FAIL create [web < 12h]: got %', v; END IF;
  -- web ohne expected_unit
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g4', 'trigger_type', 'threshold',
    'acquisition_method', 'web_search', 'acquisition_prompt', 'x',
    'comparator', 'gte', 'threshold_value', 5, 'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%unit%' THEN
    RAISE EXCEPTION 'FAIL create [web ohne unit]: got %', v; END IF;
  -- SQL-Shape: non-SELECT / Multi-Statement
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g5', 'trigger_type', 'recurring_info',
    'acquisition_method', 'sql', 'acquisition_sql', 'UPDATE agent.core_contexts SET content = NULL',
    'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL create [sql non-select]: got %', v; END IF;
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g6', 'trigger_type', 'recurring_info',
    'acquisition_method', 'sql', 'acquisition_sql', 'SELECT 1; DROP TABLE agent.monitor_triggers',
    'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL create [sql multi]: got %', v; END IF;
  -- unbekannte (nicht registrierte) Beschaffungs-Methode (Phase B: Registry statt IN-Liste)
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g7', 'trigger_type', 'threshold',
    'acquisition_method', 'zz_unknown', 'acquisition_params', jsonb_build_object('a', 1),
    'comparator', 'gte', 'threshold_value', 5, 'check_interval', '1 day'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%unknown acquisition_method%' THEN
    RAISE EXCEPTION 'FAIL create [unknown method]: got %', v; END IF;
  -- unparsebare check_interval
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'g8', 'trigger_type', 'date',
    'due_date', '2027-01-01', 'check_interval', 'oft'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%interval%' THEN
    RAISE EXCEPTION 'FAIL create [bad interval]: got %', v; END IF;
  -- kein Guard-Write passiert
  SELECT COUNT(*) INTO v_cnt FROM agent.monitor_triggers
   WHERE domain = '__test__' AND label IN ('g1','g2','g3','g4','g5','g6','g7','g8');
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL create [guards]: % Guard-Faelle wurden trotzdem geschrieben', v_cnt;
  END IF;
  RAISE NOTICE 'PASS create [alle Guards: {ok:false} ohne Write]';

  -- TEST 7 (DB-Gesetz-Backstop): Direkt-INSERT mit Typ-Inkonsistenz -> check_violation
  BEGIN
    INSERT INTO agent.monitor_triggers
      (domain, label, trigger_type, acquisition_method, due_date, check_interval)
    VALUES ('__test__', 'backstop1', 'threshold', 'none', NULL, INTERVAL '1 day');
    RAISE EXCEPTION 'FAIL monitor_triggers [type CHECK]: inkonsistenter INSERT akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS monitor_triggers [CHECK: Typ-Konsistenz ist DB-Gesetz]';
  END;
  BEGIN
    INSERT INTO agent.monitor_triggers
      (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator,
       threshold_value, expected_unit, check_interval)
    VALUES ('__test__', 'backstop2', 'threshold', 'web_search', '{"prompt":"x"}', 'gte',
            5, 'X', INTERVAL '6 hours');
    RAISE EXCEPTION 'FAIL monitor_triggers [web rate CHECK]: 6h-Web-INSERT akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS monitor_triggers [CHECK: Web-Rate-Limit ist DB-Gesetz]';
  END;

  -- TEST 8 (package-Ownership, Advisor<->Monitor): expliziter Wert wird gespeichert, Default = 'core',
  -- Format-Verstoss -> freundlich {ok:false} (kein $fromAI; CHECK = Backstop).
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'package', 'finance', 'label', 'Pkg explicit finance',
    'trigger_type', 'date', 'due_date', '2027-03-01', 'check_interval', '7 days'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL create [package explicit]: got %', v; END IF;
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = (v->>'trigger_id')::int;
  IF v_row.package IS DISTINCT FROM 'finance' THEN
    RAISE EXCEPTION 'FAIL create [package explicit]: package=% (erwartet finance)', v_row.package; END IF;
  -- Default 'core', wenn nicht uebergeben
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', 'Pkg default core',
    'trigger_type', 'date', 'due_date', '2027-04-01', 'check_interval', '7 days'));
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE id = (v->>'trigger_id')::int;
  IF v_row.package IS DISTINCT FROM 'core' THEN
    RAISE EXCEPTION 'FAIL create [package default]: package=% (erwartet core)', v_row.package; END IF;
  -- Format-Verstoss -> {ok:false}, kein Write
  v := agent.fn_create_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'package', 'Fin-ance!', 'label', 'Pkg bad fmt',
    'trigger_type', 'date', 'due_date', '2027-05-01', 'check_interval', '7 days'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%package%' THEN
    RAISE EXCEPTION 'FAIL create [package bad fmt]: got %', v; END IF;
  RAISE NOTICE 'PASS create [package: explizit gespeichert / Default core / Format-Guard]';

END $$;

ROLLBACK;
