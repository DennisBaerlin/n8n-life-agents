-- tests/db/finance/test_fn_advisor_review_told_priority.sql
-- finance.fn_advisor_review: told_keys, priority je Alarm, Kurs-Luecken nur im Digest, Teil-Plan ohne Fehlalarm.
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';

CREATE OR REPLACE FUNCTION pg_temp.alert(r jsonb, k text) RETURNS jsonb LANGUAGE sql AS $$
  SELECT a FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = k LIMIT 1;
$$;
CREATE OR REPLACE FUNCTION pg_temp.has_tpl(j jsonb, k text) RETURNS boolean LANGUAGE sql AS $$
  SELECT position('"' || k || '"' IN j::text) > 0;
$$;

DO $$
DECLARE v_a int; v_b int; v_g int; v_goal int; r jsonb; v jsonb; v_prio_missing text;
BEGIN
  -- reserve_coverage: zwei Konten -> latch_keys und told_keys je Konto
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tp_a__','cash','EUR','active') RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tp_b__','cash','EUR','active') RETURNING id INTO v_b;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tp_g__', 9000, current_date + 3650, 'active') RETURNING id INTO v_g;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_a, 600, current_date - 10, 'transfer', v_g, gen_random_uuid()),
    (v_b, 600, current_date - 10, 'transfer', v_g, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES
    (v_a, -100, current_date - 1, 'other'), (v_b, -100, current_date - 1, 'other');

  -- Sparziel erreicht
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tp_done__', 100, current_date + 3650, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_a, 200, current_date - 5, 'transfer', v_goal, gen_random_uuid());
  UPDATE finance.accounts SET status = status WHERE id = v_a;

  -- Cashflow-Defizit
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__tp_sal__', v_a, 1000, 'month', current_date, current_date),
    ('__tp_rent__', v_a, -2000, 'month', current_date, current_date);

  r := finance.fn_advisor_review('finance');

  v := pg_temp.alert(r, 'reserve_coverage');
  IF v IS NULL THEN RAISE EXCEPTION 'FAIL [reserve_coverage fehlt]: %', r->'alerts'; END IF;
  IF NOT (v->'latch_keys' @> to_jsonb(ARRAY[v_a::text, v_b::text])) THEN RAISE EXCEPTION 'FAIL [latch_keys je Konto]: %', v; END IF;
  IF NOT (v->'told_keys' @> jsonb_build_array(jsonb_build_object('source','finance:told_owner','key','reserve_breach:' || v_a,'latch_key',v_a::text))) THEN
    RAISE EXCEPTION 'FAIL [told je Konto]: %', v->'told_keys'; END IF;
  IF (v->>'priority')::int <> 90 THEN RAISE EXCEPTION 'FAIL [priority reserve]: %', v->>'priority'; END IF;

  v := pg_temp.alert(r, 'cashflow_coverage');
  IF v IS NULL OR v->'told_keys' <> '[{"source":"finance:told_owner","key":"cashflow_coverage"}]'::jsonb OR (v->>'priority')::int <> 100 THEN
    RAISE EXCEPTION 'FAIL [cashflow told/priority]: %', v; END IF;

  v := pg_temp.alert(r, 'savings_goal_reached');
  IF v IS NULL OR v->'told_keys' <> jsonb_build_array(jsonb_build_object('source','finance:told_owner','key','savings_goal_reached:' || v_goal))
     OR (v->>'priority')::int <> 30 THEN
    RAISE EXCEPTION 'FAIL [goal_reached told/priority]: %', v; END IF;

  -- jeder Alarm traegt eine Zahl
  SELECT string_agg(a->>'kind', ',') INTO v_prio_missing FROM jsonb_array_elements(r->'alerts') a WHERE jsonb_typeof(a->'priority') <> 'number' OR a->'priority' IS NULL;
  IF v_prio_missing IS NOT NULL THEN RAISE EXCEPTION 'FAIL [priority fehlt]: %', v_prio_missing; END IF;
  RAISE NOTICE 'PASS told_keys/priority (cashflow, reserve, goal)';
END $$;

-- savings_squeeze: told + priority
DO $$
DECLARE v_acct int; v_depot int; v_rp int; r jsonb; v jsonb;
BEGIN
  UPDATE finance.recurring_payments SET status = 'paused';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tp_c__','cash','EUR','active') RETURNING id INTO v_acct;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__tp_d__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__tp_s2__', v_acct, 2000, 'month', current_date, current_date),
    ('__tp_r2__', v_acct, -500, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__tp_etf__', v_acct, -1800, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id) VALUES ('__tp_plan__', v_depot, 'TPW', 'World', v_rp);
  r := finance.fn_advisor_review('finance');
  v := pg_temp.alert(r, 'savings_squeeze');
  IF v IS NULL OR v->'told_keys' <> '[{"source":"finance:told_owner","key":"savings_squeeze"}]'::jsonb OR (v->>'priority')::int <> 60 THEN
    RAISE EXCEPTION 'FAIL [squeeze told/priority]: %', v; END IF;
  RAISE NOTICE 'PASS squeeze';
END $$;

-- Kurs-Luecken: nie im Alarmtext, immer im Digest
DO $$
DECLARE v_depot int; v_set int; r jsonb; v jsonb;
BEGIN
  SELECT id INTO v_set FROM finance.accounts WHERE name = '__tp_c__';
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__tp_dep__','stocks_depot','EUR','active', v_set) RETURNING id INTO v_depot;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_depot, 'TPNOPX', 'Musterfonds', 1, 10, 'EUR', 'outside_plan');

  r := finance.fn_advisor_review('finance');
  IF pg_temp.alert(r, 'data_quality') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [nur Kurs-Luecke -> kein data_quality]: %', pg_temp.alert(r, 'data_quality'); END IF;
  IF NOT pg_temp.has_tpl(r->'digest'->'lines', 'finance.advisor.dq_null_price') THEN
    RAISE EXCEPTION 'FAIL [nur Kurs-Luecke: Digest nennt sie]'; END IF;

  -- anderer Grund (Position ohne Klasse) -> Alarm ohne Kurs-Satz, Digest mit
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'TPNOTAG', 'Ohne Klasse', 1, 10, 'EUR');
  r := finance.fn_advisor_review('finance');
  v := pg_temp.alert(r, 'data_quality');
  IF v IS NULL THEN RAISE EXCEPTION 'FAIL [data_quality erwartet]'; END IF;
  IF pg_temp.has_tpl(v->'msg', 'finance.advisor.dq_null_price') THEN RAISE EXCEPTION 'FAIL [Kurs-Satz im Alarm]: %', v->'msg'; END IF;
  IF NOT pg_temp.has_tpl(r->'digest'->'lines', 'finance.advisor.dq_null_price') THEN RAISE EXCEPTION 'FAIL [Digest ohne Kurs-Satz]'; END IF;
  IF (v->>'priority')::int <> 10 THEN RAISE EXCEPTION 'FAIL [priority dq]'; END IF;
  RAISE NOTICE 'PASS Kurs-Luecken';
END $$;

-- Teil-Plan: fehlende Bloecke -> keine Plan-Alarme, Digest wirft nicht
DO $$
DECLARE r jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('financial_planning', 'test', NULL, 'lazy', 'x', 'agent', 'finance',
          jsonb_build_object('facts', jsonb_build_object('_meta', jsonb_build_object('last_confirmed_at', current_date::text))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, managed_by = 'agent', package = 'finance';
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' IN ('allocation_drift','target_portfolio')) THEN
    RAISE EXCEPTION 'FAIL [Teil-Plan ohne Plan-Metrik]: %', r->'alerts'; END IF;
  IF jsonb_typeof(r->'digest'->'lines') <> 'array' THEN RAISE EXCEPTION 'FAIL [Digest]'; END IF;
  RAISE NOTICE 'PASS Teil-Plan';
END $$;
ROLLBACK;
