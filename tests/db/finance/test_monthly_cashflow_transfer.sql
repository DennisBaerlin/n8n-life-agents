-- tests/db/finance/test_monthly_cashflow_transfer.sql
-- WS-2 (Multi-Member): Doppelzaehl-Schutz im Cashflow.
--   monthly_cashflow_overview/_summary schliessen interne Transfers strukturell aus
--   (WHERE target_account_id IS NULL) — eine Transfer-rp darf NICHT als Haushalts-Ausgabe zaehlen,
--   eine gewoehnliche/Spar-rp schon. Delta-Messung (robust gegen vorhandene Seed-Zeilen).
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_src      INT;
  v_dst      INT;
  v_exp_cnt0 INT;
  v_exp_sum0 NUMERIC;
  v_exp_cnt1 INT;
  v_exp_sum1 NUMERIC;
  v_in_overview INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_cf_src__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_src := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_cf_dst__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_dst := (v_result->>'account_id')::int;

  -- Baseline (vor unseren rps)
  SELECT consumption_count, monthly_consumption INTO v_exp_cnt0, v_exp_sum0 FROM finance.monthly_cashflow_summary;

  -- (a) gewoehnliche Ausgabe -200/Monat (KEIN target) -> zaehlt
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__test_cf_expense__', 'account_id', v_src, 'direction','expense',
    'amount', 200, 'schedule_unit','month', 'first_payment_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [setup expense]: %', v_result;
  END IF;

  -- (b) interner Transfer 200/Monat src->dst (target gesetzt) -> zaehlt NICHT
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','__test_cf_transfer__', 'from_account_id', v_src, 'to_account_id', v_dst,
    'amount', 200, 'schedule_unit','month', 'first_payment_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [setup transfer]: %', v_result;
  END IF;

  SELECT consumption_count, monthly_consumption INTO v_exp_cnt1, v_exp_sum1 FROM finance.monthly_cashflow_summary;

  -- Genau EINE neue Konsum-Zeile (die gewoehnliche), NICHT zwei (Transfer ausgeschlossen)
  IF (v_exp_cnt1 - v_exp_cnt0) <> 1 THEN
    RAISE EXCEPTION 'FAIL [count]: consumption_count-Delta erwartet 1 (nur gewoehnliche rp), got % (Transfer fehl-gezaehlt?)', (v_exp_cnt1 - v_exp_cnt0);
  END IF;
  -- Betrags-Delta = -200 (nur die gewoehnliche), nicht -400
  IF (v_exp_sum1 - v_exp_sum0) IS DISTINCT FROM -200 THEN
    RAISE EXCEPTION 'FAIL [sum]: monthly_consumption-Delta erwartet -200, got %', (v_exp_sum1 - v_exp_sum0);
  END IF;
  RAISE NOTICE 'PASS [summary]: nur gewoehnliche rp zaehlt (Delta count=1, sum=-200)';

  -- Die Transfer-rp erscheint nicht im Overview-Detail
  SELECT count(*) INTO v_in_overview FROM finance.monthly_cashflow_overview WHERE name = '__test_cf_transfer__';
  IF v_in_overview <> 0 THEN
    RAISE EXCEPTION 'FAIL [overview]: Transfer-rp erscheint im monthly_cashflow_overview (count=%)', v_in_overview;
  END IF;
  -- Die gewoehnliche rp schon
  IF (SELECT count(*) FROM finance.monthly_cashflow_overview WHERE name = '__test_cf_expense__') <> 1 THEN
    RAISE EXCEPTION 'FAIL [overview]: gewoehnliche rp fehlt im monthly_cashflow_overview';
  END IF;
  RAISE NOTICE 'PASS [overview]: Transfer ausgeschlossen, gewoehnliche rp enthalten';
END $$;

ROLLBACK;
