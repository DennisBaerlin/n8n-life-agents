-- tests/db/finance/test_fn_resolve_savings_goal.sql
-- Testet fn_resolve_savings_goal: 1 / 0 / >1 Treffer
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_id1 INT; v_id INT; v_count INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rsg_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_sg_dup__','target_amount',5000,'target_date','2027-12-31','monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_sg_dup__','target_amount',6000,'target_date','2027-12-31','monthly_savings_rate',120,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_sg_uniq__','target_amount',8000,'target_date','2027-12-31','monthly_savings_rate',150,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  v_id1 := (v_res->>'goal_id')::int;

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_uniq__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [unique]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_goal [unique]';

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [none]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_goal [none]';

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_dup__');
  IF v_count IS DISTINCT FROM 2 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [dup]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_goal [dup]';
END $$;

ROLLBACK;
