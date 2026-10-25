-- tests/db/finance/test_fn_create_loan_status.sql
-- Testet: fn_create_loan leitet status korrekt ab (active wenn Annuität gesetzt, paused wenn NULL).
-- Testet: CHECK-Constraint verhindert status='active' ohne Raten-Kette (WP2, finance:V026: aktiv <=> recurring_payment_id).
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_debit_id INT;
  v_loan_id  INT;
  v_status   finance.loan_status;
  v_rp_id    INT;
BEGIN

  -- Hilfskonto
  SELECT finance.fn_create_account(
    '{"name":"__test_lstatus_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit_id := (v_result->>'account_id')::int;

  -- TEST 1: Kredit MIT Annuität → status muss 'active' sein
  SELECT finance.fn_create_loan(
    jsonb_build_object(
      'name',             '__test_loan_active__',
      'lender',           'TestBank',
      'borrower',         'Test',
      'original_amount',  100000,
      'disbursement_date','2024-01-15',
      'interest_rate',    '3.0',
      'monthly_annuity',  500,
      'schedule_day_of_month', 15,
      'first_payment_date', '2024-02-15',
      'debit_account_id', v_debit_id
    )
  ) INTO v_result;
  v_loan_id := (v_result->>'loan_id')::int;

  SELECT status INTO v_status FROM finance.loans WHERE id = v_loan_id;
  IF v_status IS DISTINCT FROM 'active'::finance.loan_status THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [status active]: erwartet active, got %', v_status;
  END IF;

  -- recurring_payment muss existieren
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  IF v_rp_id IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [status active]: recurring_payment_id fehlt bei Annuität';
  END IF;

  RAISE NOTICE 'PASS fn_create_loan [status active]: loan_id=%, rp_id=%', v_loan_id, v_rp_id;

  -- TEST 2: Kredit OHNE Annuität (Familienkredit/Pausiert) → status muss 'paused' sein
  SELECT finance.fn_create_loan(
    jsonb_build_object(
      'name',             '__test_loan_paused__',
      'lender',           'Familia',
      'borrower',         'Test',
      'original_amount',  5000,
      'disbursement_date','2023-06-01',
      'interest_rate',    '0.0',
      'debit_account_id', v_debit_id
    )
  ) INTO v_result;
  v_loan_id := (v_result->>'loan_id')::int;

  SELECT status INTO v_status FROM finance.loans WHERE id = v_loan_id;
  IF v_status IS DISTINCT FROM 'paused'::finance.loan_status THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [status paused]: erwartet paused, got %', v_status;
  END IF;

  -- recurring_payment darf NICHT existieren
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  IF v_rp_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [status paused]: recurring_payment_id sollte NULL sein, got %', v_rp_id;
  END IF;

  RAISE NOTICE 'PASS fn_create_loan [status paused]: loan_id=%, kein rp', v_loan_id;

  -- TEST 3: CHECK-Constraint verhindert direktes INSERT ohne Raten-Kette + status='active'
  BEGIN
    INSERT INTO finance.loans
      (name, lender, original_amount, disbursement_date, interest_rate,
       recurring_payment_id, status, loan_account_id, debit_account_id)
    VALUES ('__test_loan_invalid__', 'X', 1000, CURRENT_DATE, 0.0,
            NULL, 'active', v_debit_id, v_debit_id);
    RAISE EXCEPTION 'FAIL fn_create_loan [check active+no_annuity]: CHECK hätte INSERT ablehnen müssen';
  EXCEPTION
    WHEN check_violation THEN
      RAISE NOTICE 'PASS fn_create_loan [check active+no_annuity]: CHECK hat korrekt abgelehnt';
    WHEN others THEN
      RAISE EXCEPTION 'FAIL fn_create_loan [check active+no_annuity]: unerwarteter Fehler %', SQLERRM;
  END;

END $$;

ROLLBACK;
