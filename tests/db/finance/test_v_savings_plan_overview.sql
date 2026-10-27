-- tests/db/finance/test_v_savings_plan_overview.sql
-- Testet finance.savings_plan_overview (Livebefund 2026-10-27: ein woechentlicher Plan bei einer Bank mit festen
--   Ausfuehrungstagen wurde als "50 pro Monat" gelesen). Eine Zeile je Plan: Betrag je Ausfuehrung, Rhythmus in
--   Klartext, Monatsbetrag, Start, naechste Ausfuehrung (kettenbewusst), geplante Aenderung.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_settle  INT;
  v_depot   INT;
  v_first   DATE := (date_trunc('month', current_date) + interval '1 month' + interval '1 day')::date;  -- der 2. des Folgemonats
  v_row     RECORD;
  v_old     INT;
  v_new     INT;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_spo_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb) INTO v_result;
  v_settle := (v_result->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id)
    VALUES ('__test_spo_depot__', 'stocks_depot', 'Trade Republic Bank GmbH', 'EUR', 'active', v_settle)
    RETURNING id INTO v_depot;

  -- TEST 1: woechentlich bei festem Bank-Kalender -> 4 Tage, 50 je Ausfuehrung, 200 im Monat, Start kuenftig
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name','__test_spo_weekly__','depot_name','__test_spo_depot__',
    'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel S&P 500',
    'amount',50,'schedule_interval',1,'schedule_unit','week','first_payment_date',v_first)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan: %', v_result; END IF;

  SELECT * INTO v_row FROM finance.savings_plan_overview WHERE name = '__test_spo_weekly__';
  IF v_row.amount_per_execution <> 50.00 OR v_row.monthly_amount <> 200.00
     OR v_row.rhythm IS DISTINCT FROM 'weekly (4 times a month, on day 2, 9, 16, 23)'
     OR v_row.starts_on IS DISTINCT FROM v_first OR v_row.next_execution IS DISTINCT FROM v_first
     OR v_row.change_from IS NOT NULL OR v_row.settlement_account_id IS DISTINCT FROM v_settle
     OR v_row.currency IS DISTINCT FROM 'EUR' OR v_row.depot_name IS DISTINCT FROM '__test_spo_depot__' THEN
    RAISE EXCEPTION 'FAIL savings_plan_overview [woechentlich]: per=% monthly=% rhythm=% starts=% next=% change=%',
      v_row.amount_per_execution, v_row.monthly_amount, v_row.rhythm, v_row.starts_on, v_row.next_execution, v_row.change_from;
  END IF;
  RAISE NOTICE 'PASS savings_plan_overview [woechentlich: 50 je Ausfuehrung, 200/Monat, Klartext, Start]';

  -- TEST 2: pausiert -> keine naechste Ausfuehrung
  SELECT finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spo_weekly__','status','paused')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL pause: %', v_result; END IF;
  SELECT * INTO v_row FROM finance.savings_plan_overview WHERE name = '__test_spo_weekly__';
  IF v_row.status IS DISTINCT FROM 'paused' OR v_row.next_execution IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL savings_plan_overview [pausiert]: status=% next=%', v_row.status, v_row.next_execution; END IF;
  RAISE NOTICE 'PASS savings_plan_overview [pausiert -> next_execution NULL]';

  -- TEST 3: laufender Plan mit geplanter Betragsaenderung (Kette: altes Glied laeuft heute, Kopf ab heute+10) ->
  --   Bedingungen von heute, next_execution auf dem alten Glied (vor dem Stichtag), change_from/new_* vom Kopf.
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit,
         schedule_days_of_month, first_payment_date, valid_from, valid_to, status)
  VALUES ('__test_spo_chain_old__', v_settle, -50, 1, 'month', '{2,9,16,23}', current_date - 40, current_date - 40,
          current_date + 10, 'active') RETURNING id INTO v_old;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit,
         schedule_days_of_month, first_payment_date, valid_from, status, predecessor_id)
  VALUES ('__test_spo_chain_new__', v_settle, -60, 1, 'month', '{2,9,16,23}', current_date - 40, current_date + 10,
          'active', v_old) RETURNING id INTO v_new;
  INSERT INTO finance.savings_plans (name, depot_id, isin, symbol, security_name, recurring_payment_id)
  VALUES ('__test_spo_chain__', v_depot, 'IE00B4L5Y983', 'IWDA', 'Beispiel World', v_new);

  SELECT * INTO v_row FROM finance.savings_plan_overview WHERE name = '__test_spo_chain__';
  IF v_row.amount_per_execution <> 50.00 OR v_row.monthly_amount <> 200.00 OR v_row.starts_on IS NOT NULL
     OR v_row.change_from IS DISTINCT FROM current_date + 10 OR v_row.new_amount_per_execution <> 60.00
     OR v_row.new_rhythm IS DISTINCT FROM 'weekly (4 times a month, on day 2, 9, 16, 23)'
     OR v_row.next_execution IS NULL OR v_row.next_execution < current_date OR v_row.next_execution >= current_date + 10
     OR EXTRACT(DAY FROM v_row.next_execution)::int NOT IN (2, 9, 16, 23) THEN
    RAISE EXCEPTION 'FAIL savings_plan_overview [geplante Aenderung]: per=% monthly=% change=% new=% next=%',
      v_row.amount_per_execution, v_row.monthly_amount, v_row.change_from, v_row.new_amount_per_execution, v_row.next_execution;
  END IF;
  RAISE NOTICE 'PASS savings_plan_overview [geplante Aenderung: heutige Bedingungen + change_from/new_*, next auf altem Glied]';
END $$;

ROLLBACK;
