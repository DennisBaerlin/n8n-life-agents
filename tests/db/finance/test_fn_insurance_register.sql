-- tests/db/finance/test_fn_insurance_register.sql
-- WS-0b (estate): finance.fn_insurance_register() = Oberflaeche-A-Lesefenster fuer das estate-Paket
-- (plain STABLE, kein Grant; im core.fn_fetch_context-DEFINER gelesen). Prueft: nur AKTIVE Policen,
-- mit den estate-relevanten Feldern (insurance_type/beneficiary/coverage_amount/claim_deadline_hours),
-- gekuendigte ausgeschlossen, Rueckgabe ist ein JSON-Array.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_ins    INT;
  v_reg    JSONB;
  v_row    JSONB;
BEGIN
  -- Debit-Konto
  SELECT finance.fn_create_account(
    '{"name":"__test_insreg_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- AKTIVE Police mit den estate-Feldern
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_insreg_life__','insurance_company','TestLV AG','policy_number','LV-1',
    'insurance_type','life','beneficiary','Ehepartner','coverage_amount','250000','claim_deadline_hours','72',
    'annual_premium','1200','schedule_unit','year','schedule_day_of_month','1',
    'valid_from','2024-01-01','first_payment_date','2024-01-01','debit_account_id',v_acct,'recurring_amount','-100'
  )) INTO v_result;
  v_ins := (v_result->>'insurance_id')::int;

  -- gekuendigte Police (muss aus dem Register fallen)
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_insreg_cancelled__','annual_premium','120','schedule_unit','year','schedule_day_of_month','1',
    'valid_from','2024-01-01','first_payment_date','2024-01-01','debit_account_id',v_acct,'recurring_amount','-10'
  )) INTO v_result;
  PERFORM finance.fn_set_insurance(jsonb_build_object(
    'insurance_id',(v_result->>'insurance_id')::int,'status','cancelled'));

  v_reg := finance.fn_insurance_register();
  IF jsonb_typeof(v_reg) <> 'array' THEN
    RAISE EXCEPTION 'FAIL fn_insurance_register: kein JSON-Array, got %', v_reg;
  END IF;

  -- Die aktive Life-Police muss mit allen estate-Feldern enthalten sein.
  SELECT e INTO v_row FROM jsonb_array_elements(v_reg) e WHERE e->>'name' = '__test_insreg_life__';
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_insurance_register: aktive Police fehlt im Register';
  END IF;
  IF (v_row->>'id')::int IS DISTINCT FROM v_ins
     OR v_row->>'insurance_type' IS DISTINCT FROM 'life'
     OR v_row->>'beneficiary' IS DISTINCT FROM 'Ehepartner'
     OR (v_row->>'coverage_amount')::numeric IS DISTINCT FROM 250000
     OR (v_row->>'claim_deadline_hours')::int IS DISTINCT FROM 72
     OR v_row->>'policy_number' IS DISTINCT FROM 'LV-1'
     OR v_row->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL fn_insurance_register: estate-Felder falsch, got %', v_row;
  END IF;

  -- Gekuendigte darf NICHT drin sein.
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_reg) e WHERE e->>'name' = '__test_insreg_cancelled__') THEN
    RAISE EXCEPTION 'FAIL fn_insurance_register: gekuendigte Police nicht ausgeschlossen';
  END IF;

  RAISE NOTICE 'PASS fn_insurance_register [aktive Police mit estate-Feldern, gekuendigte ausgeschlossen, JSON-Array]';
END $$;

ROLLBACK;
