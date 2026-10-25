-- tests/db/finance/test_fn_resolve_loan.sql
-- Testet fn_resolve_loan: Loan-Name->IDs (1 Treffer) bzw. hit_count=0 bei unbekanntem Namen.
BEGIN;

DO $$
DECLARE v_debit INT; v_loan_id INT; v_hits INT;
BEGIN
  SELECT (finance.fn_create_account(
    '{"name":"__rl_debit__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb
  )->>'account_id')::int INTO v_debit;

  PERFORM finance.fn_create_loan(jsonb_build_object(
    'name','__rl_loan__','lender','TestBank','borrower','T','original_amount','100000',
    'disbursement_date','2024-01-01','interest_rate','3','interest_rate_fixed_until','2034-01-01','monthly_annuity','500','schedule_day_of_month','1',
    'first_payment_date','2024-02-01','debit_account_id', v_debit));   -- Rate => erstes Ratendatum Pflicht

  -- 1 Treffer -> loan_id gesetzt
  SELECT loan_id, hit_count INTO v_loan_id, v_hits FROM finance.fn_resolve_loan('__rl_loan__');
  IF v_hits <> 1 OR v_loan_id IS NULL THEN RAISE EXCEPTION 'FAIL resolve_loan [1 hit]: hits=%, id=%', v_hits, v_loan_id; END IF;

  -- 0 Treffer
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_loan('__nope_loan__');
  IF v_hits <> 0 THEN RAISE EXCEPTION 'FAIL resolve_loan [0]: hits=%', v_hits; END IF;

  -- paused-Kredit (keine Annuitaet -> status='paused'): per Default (active_only) NICHT gefunden,
  -- mit p_active_only=FALSE gefunden (delete_loan/settle_loan/sell brauchen das).
  PERFORM finance.fn_create_loan(jsonb_build_object(
    'name','__rl_paused__','lender','TestBank','borrower','T','original_amount','5000',
    'disbursement_date','2024-01-01','interest_rate','3','debit_account_id', v_debit));
  SELECT hit_count INTO v_hits FROM finance.fn_resolve_loan('__rl_paused__');               -- default TRUE
  IF v_hits IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL resolve_loan [paused active-only]: hits=%', v_hits; END IF;
  SELECT loan_id, hit_count INTO v_loan_id, v_hits FROM finance.fn_resolve_loan('__rl_paused__', FALSE);  -- include inactive
  IF v_hits IS DISTINCT FROM 1 OR v_loan_id IS NULL THEN RAISE EXCEPTION 'FAIL resolve_loan [paused all]: hits=%, id=%', v_hits, v_loan_id; END IF;

  RAISE NOTICE 'PASS fn_resolve_loan: 1-Treffer (loan_id=%) + 0-Treffer + p_active_only-Flag', v_loan_id;
END $$;

ROLLBACK;
