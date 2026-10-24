-- tests/db/finance/test_fn_set_insurance.sql
-- Testet fn_set_insurance: Praemie + Recurring-Sync, monthly_equivalent (GENERATED),
-- Kuendigungs-Kaskade (recurring paused + valid_to), neg-Praemie
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_id     INT;
  v_rp     INT;
  v_prem   NUMERIC;
  v_me     NUMERIC;
  v_amt    NUMERIC;
  v_istat  TEXT;
  v_rpstat TEXT;
  v_rpto   DATE;
BEGIN

  -- Setup: Konto + Versicherung (monatlich 10 -> Jahrespraemie 120)
  SELECT finance.fn_create_account('{"name":"__test_setins_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_set_ins__','annual_premium',120,'schedule_unit','month','schedule_day_of_month',1,
    'valid_from','2026-01-01','first_payment_date','2026-01-01','debit_account_id',v_acct,'recurring_amount',-10,'policyholder','Erika'
  )) INTO v_res;
  v_id := (v_res->>'insurance_id')::int;
  v_rp := (v_res->>'recurring_payment_id')::int;

  -- TEST 1: Praemie 120 -> 180 (monatlich -15, von der fn abgeleitet); Recurring-Sync + monthly_equivalent neu (15).
  -- Ein mitgeliefertes recurring_amount (-999) wird ignoriert (eine Rechen-Adresse: fn_insurance_period_amount).
  SELECT finance.fn_set_insurance(jsonb_build_object(
    'insurance_id', v_id, 'annual_premium', 180, 'recurring_amount', -999
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_insurance [ok]: %', v_res;
  END IF;
  SELECT annual_premium, monthly_equivalent INTO v_prem, v_me FROM finance.insurances WHERE id = v_id;
  IF v_prem IS DISTINCT FROM 180 OR v_me IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION 'FAIL set_insurance [premium/me]: premium=% me=% (erwartet 180/15)', v_prem, v_me;
  END IF;
  SELECT amount INTO v_amt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_amt IS DISTINCT FROM -15 THEN
    RAISE EXCEPTION 'FAIL set_insurance [recurring-sync]: amount erwartet -15, got %', v_amt;
  END IF;
  RAISE NOTICE 'PASS set_insurance [Praemie 180, me=15, recurring amount=-15]';

  -- TEST 2: Kuendigung (status=cancelled, valid_to) -> Versicherung cancelled + recurring paused + valid_to
  SELECT finance.fn_set_insurance(jsonb_build_object(
    'insurance_id', v_id, 'status', 'cancelled', 'valid_to', '2026-06-30'
  )) INTO v_res;
  SELECT status::text INTO v_istat FROM finance.insurances WHERE id = v_id;
  SELECT status::text, valid_to INTO v_rpstat, v_rpto FROM finance.recurring_payments WHERE id = v_rp;
  IF v_istat IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'FAIL set_insurance [cancelled]: erwartet cancelled, got %', v_istat;
  END IF;
  -- Eingabe = letzter Vertragstag 30.06. (inklusiv) -> gespeichert exklusiv 01.07.
  IF v_rpstat IS DISTINCT FROM 'paused' OR v_rpto IS DISTINCT FROM DATE '2026-07-01' THEN
    RAISE EXCEPTION 'FAIL set_insurance [kaskade]: recurring status=% valid_to=% (erwartet paused/2026-07-01 exklusiv)', v_rpstat, v_rpto;
  END IF;
  RAISE NOTICE 'PASS set_insurance [Kuendigung: insurance cancelled, recurring paused + valid_to]';

  -- TEST 3: negative Praemie -> {ok:false}
  SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id, 'annual_premium', -10)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_insurance [neg]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_insurance [neg premium -> ok:false]';

  -- TEST 4: valid_to (Kuendigung) vor valid_from (Vertragsbeginn 2026-01-01) -> {ok:false}
  SELECT finance.fn_set_insurance(jsonb_build_object(
    'insurance_id', v_id, 'status', 'cancelled', 'valid_to', '2025-12-31'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_insurance [valid_to<valid_from]: erwartet ok=false, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS set_insurance [valid_to vor valid_from -> ok:false]';

  -- TEST 5 (WS-0b estate): additive Nachlass-Felder partiell setzen -> persistiert, nur gelieferte Felder.
  SELECT finance.fn_set_insurance(jsonb_build_object(
    'insurance_id', v_id, 'insurance_type', 'life', 'beneficiary', 'Ehepartner',
    'coverage_amount', '300000', 'claim_deadline_hours', '72'
  )) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_insurance [estate ok]: %', v_res;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM finance.insurances
    WHERE id = v_id AND insurance_type = 'life' AND beneficiary = 'Ehepartner'
      AND coverage_amount = 300000 AND claim_deadline_hours = 72
  ) THEN
    RAISE EXCEPTION 'FAIL set_insurance [estate-Felder]: insurance_type/beneficiary/coverage_amount/claim_deadline_hours nicht gesetzt';
  END IF;
  RAISE NOTICE 'PASS set_insurance [estate-Felder partiell gesetzt]';

  -- TEST 6 (Import-Haertung 2026-10-22): ungueltige Werte -> {ok:false} OHNE Write (vorher CHECK-/Cast-RAISE);
  -- Text "75.000" wird 75000 (Tausenderpunkt).
  DECLARE v_case JSONB; BEGIN
    FOREACH v_case IN ARRAY ARRAY[
        jsonb_build_object('insurance_type', 'nope'),
        jsonb_build_object('status', 'gekuendigt'),
        jsonb_build_object('schedule_unit', 'yearly'),
        jsonb_build_object('coverage_amount', '-5'),
        jsonb_build_object('claim_deadline_hours', '12.5')] LOOP
      SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id) || v_case) INTO v_res;
      IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL set_insurance [guard %]: ok:false erwartet, got %', v_case, v_res;
      END IF;
    END LOOP;
    IF NOT EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_id AND insurance_type = 'life'
                     AND coverage_amount = 300000 AND claim_deadline_hours = 72) THEN
      RAISE EXCEPTION 'FAIL set_insurance [guard]: abgelehnte Aenderungen duerfen nichts schreiben';
    END IF;
    SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id, 'coverage_amount', '75.000')) INTO v_res;
    IF (SELECT coverage_amount FROM finance.insurances WHERE id = v_id) IS DISTINCT FROM 75000 THEN
      RAISE EXCEPTION 'FAIL set_insurance [parse]: "75.000" -> 75000 erwartet';
    END IF;
  END;
  RAISE NOTICE 'PASS set_insurance [Typ/Status/Rhythmus/Summe/Frist -> ok:false ohne Write; "75.000" -> 75000]';

  -- TEST 7 (Audit-Fund F): Vertragsende wird in die Rate gespiegelt; Kuendigung zum KUENFTIGEN Ende pausiert
  -- nicht sofort (Beitraege laufen bis dahin), Rhythmus-Wechsel leitet die Rate aus der bestehenden Praemie ab.
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_set_ins_end__','annual_premium',120,'schedule_unit','month','valid_from','2026-01-01','first_payment_date','2026-01-01',
    'debit_account_id',v_acct)) INTO v_res;
  v_id := (v_res->>'insurance_id')::int;
  v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id,
    'valid_to', (CURRENT_DATE + 60)::text)) INTO v_res;
  SELECT status::text, valid_to INTO v_rpstat, v_rpto FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpstat IS DISTINCT FROM 'active' OR v_rpto IS DISTINCT FROM CURRENT_DATE + 61 THEN
    RAISE EXCEPTION 'FAIL set_insurance [valid_to-Spiegel]: rp status=% valid_to=% (erwartet active/+61 exklusiv)', v_rpstat, v_rpto;
  END IF;
  SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id, 'status', 'cancelled')) INTO v_res;
  SELECT status::text, valid_to INTO v_rpstat, v_rpto FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpstat IS DISTINCT FROM 'active' OR v_rpto IS DISTINCT FROM CURRENT_DATE + 61 THEN
    RAISE EXCEPTION 'FAIL set_insurance [kuenftige Kuendigung]: rp status=% valid_to=% (erwartet active/+61 exklusiv)', v_rpstat, v_rpto;
  END IF;
  SELECT finance.fn_set_insurance(jsonb_build_object('insurance_id', v_id, 'schedule_unit', 'year')) INTO v_res;
  SELECT amount INTO v_amt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_amt IS DISTINCT FROM -120 THEN
    RAISE EXCEPTION 'FAIL set_insurance [rhythmus]: jaehrlich aus Praemie 120 -> -120 erwartet, got %', v_amt;
  END IF;
  RAISE NOTICE 'PASS set_insurance [Vertragsende gespiegelt, kuenftige Kuendigung pausiert nicht, Rhythmus-Rate abgeleitet]';

END $$;

ROLLBACK;
