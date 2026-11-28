-- tests/db/finance/test_fn_resolve_savings_goal.sql
-- Testet fn_resolve_savings_goal: 1 / 0 / >1 Treffer
BEGIN;
-- Fixture: ein Sparziel braucht ein Sparkonto (Topf) fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_id1 INT; v_id INT; v_count INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rsg_acct__","account_type":"cash"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_sg_dup__','target_amount',5000,'target_date','2027-12-31','monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_sg_dup_b__','target_amount',6000,'target_date','2027-12-31','monthly_savings_rate',120,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  -- Bestands-Dublette (sql.md: legitim, die create-fn lehnt eine neue ab) -> per UPDATE nachgestellt
  UPDATE finance.savings_goals SET name = '__test_sg_dup__' WHERE name = '__test_sg_dup_b__';
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
  -- TEST 4: p_active_only NULL = aktive zuerst, ohne aktiven Treffer alle (die Aendern-Werkzeuge finden so auch Nicht-Aktives)
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE name = '__test_sg_uniq__';
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_uniq__');
  IF v_count IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL resolve_savings_goal [Standard nur aktive]: count=%', v_count; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_uniq__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.savings_goals x WHERE x.name = '__test_sg_uniq__') THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [NULL findet Nicht-Aktives]: count=% id=%', v_count, v_id; END IF;
  -- zwei gleichnamige, eine nicht aktiv: NULL nimmt die aktive, FALSE meldet beide
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = (SELECT min(x.id) FROM finance.savings_goals x WHERE x.name = '__test_sg_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT max(x.id) FROM finance.savings_goals x WHERE x.name = '__test_sg_dup__') THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [NULL bevorzugt die aktive]: count=% id=%', v_count, v_id; END IF;
  SELECT hit_count INTO v_count FROM finance.fn_resolve_savings_goal('__test_sg_dup__', FALSE);
  IF v_count IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL resolve_savings_goal [FALSE meldet beide]: count=%', v_count; END IF;
  -- "aktive zuerst" gilt ueber beide Treffer-Stufen: die aktive mit anderer Gross-/Kleinschreibung schlaegt die nicht aktive mit exaktem Namen
  UPDATE finance.savings_goals SET name = '__TEST_SG_DUP__' WHERE id = (SELECT max(x.id) FROM finance.savings_goals x WHERE x.name = '__test_sg_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_savings_goal('__test_sg_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.savings_goals x WHERE x.name = '__TEST_SG_DUP__') THEN
    RAISE EXCEPTION 'FAIL resolve_savings_goal [NULL: aktive (andere Schreibweise) vor nicht aktiver (exakt)]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_savings_goal [NULL: aktive zuerst, sonst alle]';

END $$;

ROLLBACK;
