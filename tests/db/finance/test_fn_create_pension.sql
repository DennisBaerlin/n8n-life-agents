-- tests/db/finance/test_fn_create_pension.sql
-- Testet fn_create_pension: Asset-Insert, optionaler Beitrag-recurring + FK, Guards.
BEGIN;

DO $$
DECLARE
  v_result    JSONB;
  v_debit_id  INT;
  v_pension_id INT;
  v_rp_id     INT;
  v_cur       NUMERIC;
  v_rp_amount NUMERIC;
  v_linked    INT;
BEGIN

  SELECT finance.fn_create_account(
    '{"name":"__test_pension_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit_id := (v_result->>'account_id')::int;

  -- TEST 1: Pension OHNE Beitrag (z.B. gesetzliche Rente, current_value optional)
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','DRV gesetzlich','pension_type','statutory','provider','Deutsche Rentenversicherung',
    'current_value',45000,'value_updated_at','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [1]: erwartet ok=true, got %', v_result;
  END IF;
  v_pension_id := (v_result->>'pension_id')::int;
  IF (v_result->>'recurring_payment_id') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [1]: ohne Beitrag darf recurring_payment_id NULL sein, got %', v_result;
  END IF;
  SELECT current_value INTO v_cur FROM finance.pension WHERE id = v_pension_id;
  IF v_cur IS DISTINCT FROM 45000 THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [1 current_value]: erwartet 45000, got %', v_cur;
  END IF;
  RAISE NOTICE 'PASS fn_create_pension [1 ohne Beitrag, pension_id=%]', v_pension_id;

  -- TEST 2: Pension MIT Beitrag -> recurring_payment (expense) + FK-Link
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','Allianz Ruerup','pension_type','ruerup','provider','Allianz',
    'current_value',12000,'contribution_amount',200,'debit_account_id',v_debit_id,
    'schedule_day_of_month',1,'first_payment_date','2026-02-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [2]: erwartet ok=true, got %', v_result;
  END IF;
  v_pension_id := (v_result->>'pension_id')::int;
  v_rp_id      := (v_result->>'recurring_payment_id')::int;
  IF v_rp_id IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [2]: recurring_payment_id ist NULL trotz Beitrag';
  END IF;
  SELECT amount INTO v_rp_amount FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_rp_amount IS DISTINCT FROM -200 THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [2 Beitrag]: recurring amount erwartet -200, got %', v_rp_amount;
  END IF;
  SELECT recurring_payment_id INTO v_linked FROM finance.pension WHERE id = v_pension_id;
  IF v_linked IS DISTINCT FROM v_rp_id THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [2 FK]: erwartet %, got %', v_rp_id, v_linked;
  END IF;
  RAISE NOTICE 'PASS fn_create_pension [2 mit Beitrag -200, FK gesetzt]';

  -- TEST 3: current_value < 0 -> {ok:false}
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','Negativ','pension_type','private','current_value',-5
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [current_value<0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_pension [current_value<0 -> ok:false]';

  -- TEST 4: Beitrag ohne debit_account -> {ok:false}
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','Beitrag ohne Konto','pension_type','riester','contribution_amount',150
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [contribution ohne debit]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_pension [contribution ohne debit -> ok:false]';

END $$;

ROLLBACK;
