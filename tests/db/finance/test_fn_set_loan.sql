-- tests/db/finance/test_fn_set_loan.sql
-- Testet fn_set_loan: GENERATED-Recompute, Recurring-Sync (Rate), Status-Kaskade,
-- active-ohne-Annuitaet-Guard, neg-Rate-Guard
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_debit INT; v_loan INT; v_rp INT;
  v_irate NUMERIC; v_arate NUMERIC; v_annuity NUMERIC; v_rpamt NUMERIC;
  v_lstatus TEXT; v_rpstatus TEXT;
  v_loan2 INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_sl_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_debit := (v_res->>'account_id')::int;

  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_loan__','lender','ING','borrower','Erika','original_amount',100000,
    'disbursement_date','2026-01-01','interest_rate',3.0,'principal_rate',2.0,
    'monthly_annuity',1200,'schedule_day_of_month',1,'first_payment_date','2026-02-01','debit_account_id',v_debit
  )) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_rp   := (v_res->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN RAISE EXCEPTION 'FAIL set_loan [setup]: keine Kreditrate-recurring angelegt'; END IF;

  -- TEST 1: Zinssatz 3.0 -> 3.5; GENERATED annuity_rate = 3.5 + 2.0 = 5.5
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', 3.5)) INTO v_res;
  SELECT interest_rate, annuity_rate INTO v_irate, v_arate FROM finance.loans WHERE id = v_loan;
  IF v_irate IS DISTINCT FROM 3.5 OR v_arate IS DISTINCT FROM 5.5 THEN
    RAISE EXCEPTION 'FAIL set_loan [generated]: interest=% annuity_rate=% (erwartet 3.5/5.5)', v_irate, v_arate; END IF;
  RAISE NOTICE 'PASS set_loan [interest 3.5 -> GENERATED annuity_rate 5.5]';

  -- TEST 2: Annuitaet 1200 -> 1000; verknuepfte recurring.amount = -1000 (Befund B)
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'monthly_annuity', 1000)) INTO v_res;
  SELECT monthly_annuity INTO v_annuity FROM finance.loans WHERE id = v_loan;
  SELECT amount INTO v_rpamt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_annuity IS DISTINCT FROM 1000 OR v_rpamt IS DISTINCT FROM -1000 THEN
    RAISE EXCEPTION 'FAIL set_loan [annuity-sync]: annuity=% rp.amount=% (erwartet 1000/-1000)', v_annuity, v_rpamt; END IF;
  RAISE NOTICE 'PASS set_loan [Annuitaet 1000 -> recurring amount -1000]';

  -- TEST 3: Status paused -> Loan paused + recurring paused (Kaskade)
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'status', 'paused')) INTO v_res;
  SELECT status::text INTO v_lstatus FROM finance.loans WHERE id = v_loan;
  SELECT status::text INTO v_rpstatus FROM finance.recurring_payments WHERE id = v_rp;
  IF v_lstatus IS DISTINCT FROM 'paused' OR v_rpstatus IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL set_loan [kaskade]: loan=% rp=% (erwartet paused/paused)', v_lstatus, v_rpstatus; END IF;
  RAISE NOTICE 'PASS set_loan [status paused -> recurring paused]';

  -- TEST 4: neg Zinssatz -> {ok:false}
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', -1)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [neg rate]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [neg rate -> ok:false]';

  -- TEST 5: paused-Kredit ohne Annuitaet -> active setzen ohne Annuitaet -> {ok:false}
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_paused__','lender','Family','borrower','Erika','original_amount',5000,
    'disbursement_date','2026-01-01','interest_rate',0.0,'debit_account_id',v_debit
  )) INTO v_res;
  v_loan2 := (v_res->>'loan_id')::int;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan2, 'status', 'active')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [active-no-annuity]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [active ohne Annuitaet -> ok:false]';
END $$;

ROLLBACK;
