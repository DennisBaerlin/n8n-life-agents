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

-- WP2 (das LLM rechnet nicht): Beitrag je Abbuchung + Rhythmus roh; der Monatswert kommt aus der Beitrags-Zeile.
DO $$
DECLARE v_res JSONB; v_giro INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_cp_rh_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_res := finance.fn_create_pension(jsonb_build_object('name','__test_cp_rh__','pension_type','private',
    'contribution_amount',600,'schedule_unit','year','first_payment_date','2026-12-01','debit_account_id',v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT contribution_amount::text || '|' || schedule_unit || '|' || monthly_contribution FROM finance.pension_overview
         WHERE id = (v_res->>'pension_id')::int) IS DISTINCT FROM '600.00|year|-50.00' THEN
    RAISE EXCEPTION 'FAIL fn_create_pension [Rhythmus]: 600 jaehrlich -> Monatswert -50 erwartet, got % / %', v_res,
      (SELECT row_to_json(o) FROM finance.pension_overview o WHERE id = (v_res->>'pension_id')::int); END IF;
  v_res := finance.fn_create_pension(jsonb_build_object('name','__test_cp_rh_bad__','pension_type','private',
    'contribution_amount',50,'schedule_unit','yearly','debit_account_id',v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL fn_create_pension [Rhythmus unbekannt]: %', v_res; END IF;
  RAISE NOTICE 'PASS fn_create_pension [600 jaehrlich roh, Monatswert -50 abgeleitet; unbekannter Rhythmus ok:false]';
END $$;
ROLLBACK;
