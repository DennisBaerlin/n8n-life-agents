-- tests/db/finance/test_fn_told_fold_interplay.sql
-- Zusammenspiel Sofort-Hinweis (Fold) und Waechter: Hoerte der Owner die Lage beim Eintragen, schweigt der Waechter;
-- buchte ein Mitglied oder fehlt der Absender, meldet er (lieber doppelt als verschluckt).
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','t',NULL,'lazy','f',
  jsonb_build_object('managed_by','agent','protected', TRUE,
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                         'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
      jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                         'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.advisors (domain, plan_context, review_fn, package)
VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance')
ON CONFLICT (domain) DO NOTHING;
UPDATE finance.recurring_payments SET status = 'paused';

CREATE OR REPLACE FUNCTION pg_temp.has_kind(r jsonb, k text) RETURNS boolean LANGUAGE sql AS $$
  SELECT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = k);
$$;
CREATE OR REPLACE FUNCTION pg_temp.reset_told() RETURNS void LANGUAGE sql AS $$
  DELETE FROM core.notification_state WHERE source IN ('finance', 'finance:told_owner', 'advisor:finance');
$$;

-- Cashflow: Pflicht > Einnahmen
DO $$
DECLARE v_acct int; r jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__tfi_giro__','cash','EUR','active') RETURNING id INTO v_acct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__tfi_sal__', v_acct, 1000, 'month', current_date, current_date),
    ('__tfi_rent__', v_acct, -2000, 'month', current_date, current_date);

  PERFORM pg_temp.reset_told();
  IF NOT (finance.fn_cashflow_coverage_fold('111') ? 'cashflow_coverage') THEN RAISE EXCEPTION 'FAIL [cf owner fold]'; END IF;
  r := core.fn_advisor_review_evaluate('finance');
  IF pg_temp.has_kind(r, 'cashflow_coverage') THEN RAISE EXCEPTION 'FAIL [cf owner -> still]: %', r; END IF;

  PERFORM pg_temp.reset_told();
  PERFORM finance.fn_cashflow_coverage_fold('222');
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'cashflow_coverage') THEN RAISE EXCEPTION 'FAIL [cf Mitglied -> Meldung]: %', r; END IF;

  PERFORM pg_temp.reset_told();
  PERFORM finance.fn_cashflow_coverage_fold();
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'cashflow_coverage') THEN RAISE EXCEPTION 'FAIL [cf ohne chat_id -> Meldung]: %', r; END IF;
  RAISE NOTICE 'PASS cashflow told';

  UPDATE finance.recurring_payments SET status = 'paused' WHERE name LIKE '__tfi_%';
END $$;

-- Sparraten leeren das Konto
DO $$
DECLARE v_acct int; v_depot int; v_rp int; r jsonb;
BEGIN
  SELECT id INTO v_acct FROM finance.accounts WHERE name = '__tfi_giro__';
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__tfi_depot__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__tfs_sal__', v_acct, 2000, 'month', current_date, current_date),
    ('__tfs_rent__', v_acct, -500, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__tfs_etf__', v_acct, -1800, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__tfs_plan__', v_depot, 'TFSW', 'World', v_rp);

  PERFORM pg_temp.reset_told();
  IF NOT (finance.fn_savings_squeeze_fold('111') ? 'savings_squeeze') THEN RAISE EXCEPTION 'FAIL [sq owner fold]'; END IF;
  r := core.fn_advisor_review_evaluate('finance');
  IF pg_temp.has_kind(r, 'savings_squeeze') THEN RAISE EXCEPTION 'FAIL [sq owner -> still]: %', r; END IF;

  PERFORM pg_temp.reset_told();
  PERFORM finance.fn_savings_squeeze_fold('222');
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'savings_squeeze') THEN RAISE EXCEPTION 'FAIL [sq Mitglied -> Meldung]: %', r; END IF;

  PERFORM pg_temp.reset_told();
  PERFORM finance.fn_savings_squeeze_fold();
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'savings_squeeze') THEN RAISE EXCEPTION 'FAIL [sq ohne chat_id -> Meldung]: %', r; END IF;
  RAISE NOTICE 'PASS squeeze told';
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name LIKE '__tfs_%';
END $$;

-- Reserve je Konto; buchen und uebertragen
DO $$
DECLARE v_res jsonb; v_a int; v_b int; v_g int; r jsonb; v_cov jsonb;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__tfr_a__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__tfr_b__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tfr_g__', 9000, current_date + 365, 'active') RETURNING id INTO v_g;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_a, 600, current_date - 10, 'transfer', v_g, gen_random_uuid()),
    (v_b, 600, current_date - 10, 'transfer', v_g, gen_random_uuid());

  PERFORM pg_temp.reset_told();
  v_res := finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','100','direction','outflow','transaction_date',current_date::text,'chat_id','111'));
  IF NOT (v_res ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL [rb fold]: %', v_res; END IF;
  r := core.fn_advisor_review_evaluate('finance');
  IF pg_temp.has_kind(r, 'reserve_coverage') THEN RAISE EXCEPTION 'FAIL [rb owner -> still]: %', r; END IF;

  -- zweites Konto per Mitglied ueber Uebertrag -> Meldung, nur dessen Element frisch
  v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_b,'to_account_id',v_a,'amount','100','transaction_date',current_date::text,'chat_id','222'));
  IF NOT (v_res ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL [rb transfer fold]: %', v_res; END IF;
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'reserve_coverage') THEN RAISE EXCEPTION 'FAIL [rb Mitglied -> Meldung]: %', r; END IF;
  SELECT a INTO v_cov FROM jsonb_array_elements(r->'alerts') a WHERE a->>'kind' = 'reserve_coverage';
  IF v_cov->'_latched' <> jsonb_build_array(jsonb_build_object('source','advisor:finance','key','reserve_coverage#' || v_b)) THEN
    RAISE EXCEPTION 'FAIL [rb nur Mitglieds-Konto frisch]: %', v_cov->'_latched'; END IF;

  -- ohne chat_id -> Meldung
  PERFORM pg_temp.reset_told();
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','10','direction','outflow','transaction_date',current_date::text));
  r := core.fn_advisor_review_evaluate('finance');
  IF NOT pg_temp.has_kind(r, 'reserve_coverage') THEN RAISE EXCEPTION 'FAIL [rb ohne chat_id -> Meldung]: %', r; END IF;
  RAISE NOTICE 'PASS reserve told';
END $$;

-- Sparziel erreicht: Merker nur fuer den Owner, Note jedes Mal
DO $$
DECLARE v_res jsonb; v_giro int; v_topf int; v_goal int; v_p2p int; v_goal2 int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__tfg_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  v_topf := (finance.fn_create_account('{"name":"__tfg_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tfg_g__', 100, current_date + 365, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 5000, current_date - 1, 'other');

  PERFORM pg_temp.reset_told();
  v_res := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf,
    'amount',100,'direction','deposit','transaction_date',current_date::text,'chat_id','222'));
  IF NOT (v_res ? 'savings_goal_reached') THEN RAISE EXCEPTION 'FAIL [sg note]: %', v_res; END IF;
  IF core.fn_notify_told('finance:told_owner', 'savings_goal_reached:' || v_goal) THEN RAISE EXCEPTION 'FAIL [sg Mitglied kein Merker]'; END IF;

  v_res := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf,
    'amount',10,'direction','deposit','transaction_date',current_date::text,'chat_id','111'));
  IF NOT (v_res ? 'savings_goal_reached') THEN RAISE EXCEPTION 'FAIL [sg zweite Note]: %', v_res; END IF;
  IF NOT core.fn_notify_told('finance:told_owner', 'savings_goal_reached:' || v_goal) THEN RAISE EXCEPTION 'FAIL [sg Owner Merker]'; END IF;

  v_res := finance.fn_book_savings_goal_transfer(jsonb_build_object('savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_topf,
    'amount',10,'direction','deposit','transaction_date',current_date::text,'chat_id','111'));
  IF NOT (v_res ? 'savings_goal_reached') THEN RAISE EXCEPTION 'FAIL [sg Note jedes Mal]: %', v_res; END IF;

  -- Reservierung
  v_p2p := (finance.fn_create_account('{"name":"__tfg_cash2__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_p2p, 500, current_date - 1, 'other');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tfg_g2__', 100, current_date + 365, 'active') RETURNING id INTO v_goal2;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id',v_goal2,'account_id',v_p2p,'amount',100,'chat_id','111'));
  IF NOT (v_res ? 'savings_goal_reached') THEN RAISE EXCEPTION 'FAIL [rsv note]: %', v_res; END IF;
  IF NOT core.fn_notify_told('finance:told_owner', 'savings_goal_reached:' || v_goal2) THEN RAISE EXCEPTION 'FAIL [rsv Owner Merker]'; END IF;
  RAISE NOTICE 'PASS Sparziel told';
END $$;
ROLLBACK;
