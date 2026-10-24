-- tests/db/finance/test_fn_set_pension.sql
-- Testet fn_set_pension: Wert-Update (value_updated_at auto), Status-Kaskade auf recurring_payment, neg-Wert
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_id     INT;
  v_rp     INT;
  v_val    NUMERIC;
  v_vdate  DATE;
  v_pstat  TEXT;
  v_rpstat TEXT;
BEGIN

  -- Setup: Konto + Rente MIT monatlichem Beitrag (-> verknuepfte recurring_payment)
  SELECT finance.fn_create_account('{"name":"__test_pen_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','__test_set_pen__','pension_type','ruerup','current_value',10000,
    'contribution_amount',150,'debit_account_id',v_acct,'first_payment_date','2026-01-01'
  )) INTO v_res;
  v_id := (v_res->>'pension_id')::int;
  v_rp := (v_res->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN
    RAISE EXCEPTION 'FAIL set_pension [setup]: keine verknuepfte recurring_payment angelegt';
  END IF;

  -- TEST 1: Wert aktualisieren ohne value_updated_at -> auto heute
  SELECT finance.fn_set_pension(jsonb_build_object('pension_id', v_id, 'current_value', 12500)) INTO v_res;
  SELECT current_value, value_updated_at INTO v_val, v_vdate FROM finance.pension WHERE id = v_id;
  IF v_val IS DISTINCT FROM 12500 OR v_vdate IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL set_pension [value]: value=% date=%', v_val, v_vdate;
  END IF;
  RAISE NOTICE 'PASS set_pension [value=12500, value_updated_at=heute]';

  -- TEST 2: Status paid_out -> Pension paid_out + verknuepfte recurring paused (Kaskade)
  SELECT finance.fn_set_pension(jsonb_build_object('pension_id', v_id, 'status', 'paid_out')) INTO v_res;
  SELECT status::text INTO v_pstat FROM finance.pension WHERE id = v_id;
  SELECT status::text INTO v_rpstat FROM finance.recurring_payments WHERE id = v_rp;
  IF v_pstat IS DISTINCT FROM 'paid_out' THEN
    RAISE EXCEPTION 'FAIL set_pension [status]: erwartet paid_out, got %', v_pstat;
  END IF;
  IF v_rpstat IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL set_pension [kaskade]: verknuepfte recurring erwartet paused, got %', v_rpstat;
  END IF;
  RAISE NOTICE 'PASS set_pension [status=paid_out -> recurring paused]';

  -- TEST 3: Reaktivierung active -> recurring wieder active
  SELECT finance.fn_set_pension(jsonb_build_object('pension_id', v_id, 'status', 'active')) INTO v_res;
  SELECT status::text INTO v_rpstat FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpstat IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL set_pension [reaktiv]: recurring erwartet active, got %', v_rpstat;
  END IF;
  RAISE NOTICE 'PASS set_pension [status=active -> recurring active]';

  -- TEST 4: negativer Wert -> {ok:false}
  SELECT finance.fn_set_pension(jsonb_build_object('pension_id', v_id, 'current_value', -1)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_pension [neg]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_pension [neg value -> ok:false]';

END $$;

ROLLBACK;
