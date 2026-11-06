-- tests/db/finance/test_fn_add_recurring_payment.sql
-- Testet den internen Helper fn_add_recurring_payment: INSERT, Vorzeichen, monthly_equivalent, valid_to.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_acct_id INT;
  v_rp_id   INT;
  v_amount  NUMERIC;
  v_me      NUMERIC;
  v_vto     DATE;
BEGIN

  -- Setup: Konto
  SELECT finance.fn_create_account(
    '{"name":"__test_addrp_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- TEST 1: Einnahme (+), monatlich -> monthly_equivalent = amount
  v_rp_id := finance.fn_add_recurring_payment(
    v_acct_id, 3000, 'Gehalt', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
    '2026-01-01'::date, NULL, NULL, NULL, NULL);
  SELECT amount, monthly_equivalent INTO v_amount, v_me
  FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_add_recurring_payment [income amount]: erwartet 3000, got %', v_amount;
  END IF;
  IF v_me IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_add_recurring_payment [monthly_equivalent monatlich]: erwartet 3000, got %', v_me;
  END IF;
  RAISE NOTICE 'PASS fn_add_recurring_payment [income, monthly_equivalent=%]', v_me;

  -- TEST 2: Ausgabe (-), jaehrlich -> monthly_equivalent = amount/12; valid_to gesetzt
  v_rp_id := finance.fn_add_recurring_payment(
    v_acct_id, -1200, 'Jahresabo', 1::smallint, 'year'::finance.schedule_unit, NULL,
    '2026-02-15'::date, '2026-02-15'::date, '2027-02-14'::date, 'active'::finance.payment_status, 'Notiz');
  SELECT amount, monthly_equivalent, valid_to INTO v_amount, v_me, v_vto
  FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM -1200 THEN
    RAISE EXCEPTION 'FAIL fn_add_recurring_payment [expense amount]: erwartet -1200, got %', v_amount;
  END IF;
  IF v_me IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL fn_add_recurring_payment [monthly_equivalent jaehrlich]: erwartet -100, got %', v_me;
  END IF;
  IF v_vto IS DISTINCT FROM '2027-02-14'::date THEN
    RAISE EXCEPTION 'FAIL fn_add_recurring_payment [valid_to]: erwartet 2027-02-14, got %', v_vto;
  END IF;
  RAISE NOTICE 'PASS fn_add_recurring_payment [expense, me=%, valid_to=%]', v_me, v_vto;

END $$;

ROLLBACK;
