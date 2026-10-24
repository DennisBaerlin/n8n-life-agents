-- tests/db/cross/test_household_protection_schema.sql
-- Testet die Phase-1-Schema-Erweiterungen ausserhalb von core_contexts:
--   * finance.pension_statements (Child-Tabelle: UNIQUE je (pension_id, statement_date), CASCADE)
--   * agent.monitor_triggers.origin    (core nie loeschbar, immer deaktivierbar; fn-Guard + Trigger-Backstop)
--   * Core-Seed household_facts_freshness (idempotent in monitor_init, origin='core')
BEGIN;

DO $$
DECLARE
  v_pension_id INT;
  v_stmt_count INT;
  v_result     JSONB;
  v_trigger_id INT;
BEGIN

  -- ---------- Fixture: eine Pension ----------
  INSERT INTO finance.pension (name, pension_type)
  VALUES ('__test_pension_stmt__', 'statutory')
  RETURNING id INTO v_pension_id;

  -- ---------- TEST 1: Statements als datierte Zeitreihe (Child, nie Parent-Rows) ----------
  INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim, projection, em_monthly, is_nominal)
  VALUES (v_pension_id, DATE '2025-06-01', 820.50, 1610.00, 1102.00, TRUE),
         (v_pension_id, DATE '2026-06-01', 870.25, 1655.00, 1140.00, TRUE);
  SELECT COUNT(*) INTO v_stmt_count FROM finance.pension_statements WHERE pension_id = v_pension_id;
  IF v_stmt_count IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL finance_pension_statements [insert]: erwartet 2 Zeilen, got %', v_stmt_count;
  END IF;
  RAISE NOTICE 'PASS finance_pension_statements [Zeitreihe, 2 datierte Snapshots]';

  -- UNIQUE (pension_id, statement_date): dieselbe Standmitteilung nie doppelt
  BEGIN
    INSERT INTO finance.pension_statements (pension_id, statement_date, reached_claim)
    VALUES (v_pension_id, DATE '2026-06-01', 999.99);
    RAISE EXCEPTION 'FAIL finance_pension_statements [unique]: Duplikat akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS finance_pension_statements [UNIQUE (pension_id, statement_date)]';
  END;

  -- CASCADE: Pension weg -> Statements weg (disposable Child gemaess ON-DELETE-Politik)
  DELETE FROM finance.pension WHERE id = v_pension_id;
  SELECT COUNT(*) INTO v_stmt_count FROM finance.pension_statements WHERE pension_id = v_pension_id;
  IF v_stmt_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL finance_pension_statements [cascade]: % Zeilen verwaist', v_stmt_count;
  END IF;
  RAISE NOTICE 'PASS finance_pension_statements [ON DELETE CASCADE]';

  -- ---------- TEST 2: Core-Seed existiert (idempotenter INSERT in monitor_init) ----------
  SELECT id INTO v_trigger_id FROM agent.monitor_triggers
  WHERE label = 'household_facts_freshness' AND origin = 'core';
  IF v_trigger_id IS NULL THEN
    RAISE EXCEPTION 'FAIL monitor core seed: household_facts_freshness (origin=core) fehlt';
  END IF;
  RAISE NOTICE 'PASS monitor core seed [household_facts_freshness, origin=core]';

  -- ---------- TEST 3: origin default 'user' ----------
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, check_interval)
  VALUES ('__test__', '__test_user_trigger__', 'recurring_info', 'sql',
          jsonb_build_object('query', 'SELECT 1'), INTERVAL '1 day');
  IF (SELECT origin FROM agent.monitor_triggers WHERE label = '__test_user_trigger__') IS DISTINCT FROM 'user' THEN
    RAISE EXCEPTION 'FAIL monitor_triggers.origin: Default ist nicht user';
  END IF;
  RAISE NOTICE 'PASS monitor_triggers.origin [Default user]';

  -- ---------- TEST 4: Core-Trigger nie loeschbar (Trigger-Backstop), aber deaktivierbar ----------
  BEGIN
    DELETE FROM agent.monitor_triggers WHERE id = v_trigger_id;
    RAISE EXCEPTION 'FAIL monitor core protect: DELETE auf origin=core akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS monitor core protect [BEFORE-DELETE-Backstop blockt origin=core]';
  END;
  UPDATE agent.monitor_triggers SET status = 'disabled' WHERE id = v_trigger_id;
  IF (SELECT status FROM agent.monitor_triggers WHERE id = v_trigger_id) IS DISTINCT FROM 'disabled' THEN
    RAISE EXCEPTION 'FAIL monitor core protect: Deaktivieren muss erlaubt bleiben';
  END IF;
  RAISE NOTICE 'PASS monitor core protect [always-silenceable: disabled ok]';

  -- ---------- TEST 5: fn_delete_monitor_trigger -> freundliches {ok:false} fuer core ----------
  SELECT agent.fn_delete_monitor_trigger(jsonb_build_object(
    'domain', (SELECT domain FROM agent.monitor_triggers WHERE id = v_trigger_id),
    'label',  'household_facts_freshness'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR v_result->>'reason' NOT ILIKE '%core%' THEN
    RAISE EXCEPTION 'FAIL fn_delete_monitor_trigger [core guard]: erwartet ok=false mit core-Hinweis, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_delete_monitor_trigger [core -> ok:false, deactivate instead]';

  -- User-Trigger bleibt normal loeschbar (kein Overblocking)
  SELECT agent.fn_delete_monitor_trigger(jsonb_build_object(
    'domain', '__test__', 'label', '__test_user_trigger__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_delete_monitor_trigger [user]: erwartet ok=true, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_delete_monitor_trigger [user-Trigger weiterhin loeschbar]';

  -- ---------- TEST 6 (Review: TRUNCATE-Backstop auf monitor_triggers) ----------
  BEGIN
    TRUNCATE agent.monitor_triggers CASCADE;
    RAISE EXCEPTION 'FAIL TRUNCATE-Backstop: monitor_triggers truncated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS TRUNCATE-Backstop [monitor_triggers: %]', SQLERRM;
  END;

  -- core_contexts-Löschschutz (registry-getrieben, WS-B2b) wird in test_core_protected_contexts.sql
  -- getestet (frueher hier TEST 7-9 ueber metadata.protected/autoprotect — beide retired).

END $$;

ROLLBACK;
