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
  SELECT finance.fn_create_account('{"name":"__test_ins_acct__","account_type":"cash"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_dup__','annual_premium',120,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-10,'policyholder','Test')) INTO v_res;
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_dup_b__','annual_premium',240,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct,'recurring_amount',-20,'policyholder','Test')) INTO v_res;
  -- Bestands-Dublette (sql.md: legitim, die create-fn lehnt eine neue ab) -> per UPDATE nachgestellt
  UPDATE finance.insurances SET name = '__test_ins_dup__' WHERE name = '__test_ins_dup_b__';
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

  -- TEST 4: p_active_only NULL = aktive zuerst, ohne aktiven Treffer alle (die Aendern-Werkzeuge finden so auch Nicht-Aktives)
  UPDATE finance.insurances SET status = 'cancelled' WHERE name = '__test_ins_uniq__';
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_uniq__');
  IF v_count IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL resolve_insurance [Standard nur aktive]: count=%', v_count; END IF;
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_uniq__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.insurances x WHERE x.name = '__test_ins_uniq__') THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [NULL findet Nicht-Aktives]: count=% id=%', v_count, v_id; END IF;
  -- zwei gleichnamige, eine nicht aktiv: NULL nimmt die aktive, FALSE meldet beide
  UPDATE finance.insurances SET status = 'cancelled' WHERE id = (SELECT min(x.id) FROM finance.insurances x WHERE x.name = '__test_ins_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT max(x.id) FROM finance.insurances x WHERE x.name = '__test_ins_dup__') THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [NULL bevorzugt die aktive]: count=% id=%', v_count, v_id; END IF;
  SELECT hit_count INTO v_count FROM finance.fn_resolve_insurance('__test_ins_dup__', FALSE);
  IF v_count IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL resolve_insurance [FALSE meldet beide]: count=%', v_count; END IF;
  -- "aktive zuerst" gilt ueber beide Treffer-Stufen: die aktive mit anderer Gross-/Kleinschreibung schlaegt die nicht aktive mit exaktem Namen
  UPDATE finance.insurances SET name = '__TEST_INS_DUP__' WHERE id = (SELECT max(x.id) FROM finance.insurances x WHERE x.name = '__test_ins_dup__');
  SELECT id, hit_count INTO v_id, v_count FROM finance.fn_resolve_insurance('__test_ins_dup__', NULL);
  IF v_count IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM (SELECT x.id FROM finance.insurances x WHERE x.name = '__TEST_INS_DUP__') THEN
    RAISE EXCEPTION 'FAIL resolve_insurance [NULL: aktive (andere Schreibweise) vor nicht aktiver (exakt)]: count=% id=%', v_count, v_id; END IF;
  RAISE NOTICE 'PASS resolve_insurance [NULL: aktive zuerst, sonst alle]';

END $$;

ROLLBACK;
