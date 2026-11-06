-- tests/db/finance/test_fn_resolve_recurring_payment.sql
-- Testet fn_resolve_recurring_payment: 1 / 0 / >1 Treffer (active-only)
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_id1 INT; v_id INT; v_count INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rrp_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- zwei aktive 'Gehalt' (Ambiguitaet) + ein eindeutiges 'Miete'
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_rrp_dup__','account_id',v_acct,'direction','income','amount',3000,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  -- Bestandspaar (vor der Namenssperre in fn_create_recurring_payment entstanden): anders anlegen, dann umbenennen
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_rrp_dup2__','account_id',v_acct,'direction','income','amount',3200,'schedule_unit','month','first_payment_date','2026-02-01')) INTO v_res;
  UPDATE finance.recurring_payments SET name = '__test_rrp_dup__' WHERE id = (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__test_rrp_uniq__','account_id',v_acct,'direction','expense','amount',900,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  v_id1 := (v_res->>'recurring_payment_id')::int;

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_recurring_payment('__test_rrp_uniq__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_recurring_payment [unique]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_recurring_payment [unique]';

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_recurring_payment('__test_rrp_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_recurring_payment [none]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_recurring_payment [none]';

  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_recurring_payment('__test_rrp_dup__');
  IF v_count IS DISTINCT FROM 2 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_recurring_payment [dup]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_recurring_payment [dup]';
END $$;

ROLLBACK;
