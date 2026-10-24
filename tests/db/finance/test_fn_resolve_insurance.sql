-- tests/db/finance/test_fn_resolve_insurance.sql
-- Testet fn_resolve_insurance: 1 Treffer, 0 Treffer, >1 Treffer (Ambiguitaet)
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_acct  INT;
  v_id1   INT;
  v_id    INT;
  v_count INT;
BEGIN

  -- Setup: Abbuchungskonto + Versicherungen
  SELECT finance.fn_create_account('{"name":"__test_ins_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_dup__','annual_premium',120,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-10,'policyholder','Test')) INTO v_res;
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_dup__','annual_premium',240,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-20,'policyholder','Test')) INTO v_res;
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_uniq__','annual_premium',360,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-30,'policyholder','Test')) INTO v_res;
  v_id1 := (v_res->>'insurance_id')::int;

  -- TEST 1: eindeutig
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_uniq__');
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_id1 THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [unique]: erwartet count=1 id=%, got count=% id=%', v_id1, v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_insurance [unique: id=%]', v_id;

  -- TEST 2: keiner
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_none__');
  IF v_count IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [none]: got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_insurance [none]';

  -- TEST 3: Ambiguitaet
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_dup__');
  IF v_count IS DISTINCT FROM 2 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [dup]: got count=% id=%', v_count, v_id;
  END IF;
  RAISE NOTICE 'PASS resolve_insurance [dup: count=2, id=NULL]';

END $$;

ROLLBACK;
