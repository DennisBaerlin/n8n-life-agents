-- tests/db/finance/test_fn_savings_rate_schedule.sql
-- Testet den read-only Helper: Ziel-getrieben (Rate berechnen) + Raten-getrieben (Datum berechnen) + Guards.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
BEGIN

  -- TEST 1: Ziel-getrieben — 12000 EUR ueber 12 Monate (first 2027-01-01 .. target 2028-01-01) -> 1000/Monat
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 12000, 'target_date', '2028-01-01', 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL schedule [target-driven]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'months')::int IS DISTINCT FROM 12 THEN
    RAISE EXCEPTION 'FAIL schedule [target-driven months]: erwartet 12, got %', v_result->>'months';
  END IF;
  IF (v_result->>'monthly_rate')::numeric IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL schedule [target-driven rate]: erwartet 1000, got %', v_result->>'monthly_rate';
  END IF;
  IF (v_result->>'target_date')::date IS DISTINCT FROM '2028-01-01'::date THEN
    RAISE EXCEPTION 'FAIL schedule [target-driven date]: erwartet 2028-01-01, got %', v_result->>'target_date';
  END IF;
  RAISE NOTICE 'PASS schedule [target-driven]: rate=%, months=%', v_result->>'monthly_rate', v_result->>'months';

  -- TEST 2: Raten-getrieben — 50000 EUR bei 200/Monat -> 250 Monate, Datum first + 250 Monate
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 50000, 'monthly_savings_rate', 200, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL schedule [rate-driven]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'months')::int IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'FAIL schedule [rate-driven months]: erwartet 250, got %', v_result->>'months';
  END IF;
  IF (v_result->>'monthly_rate')::numeric IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL schedule [rate-driven rate]: erwartet 200, got %', v_result->>'monthly_rate';
  END IF;
  IF (v_result->>'target_date')::date IS DISTINCT FROM ('2027-01-01'::date + INTERVAL '250 months')::date THEN
    RAISE EXCEPTION 'FAIL schedule [rate-driven date]: erwartet %, got %',
      ('2027-01-01'::date + INTERVAL '250 months')::date, v_result->>'target_date';
  END IF;
  RAISE NOTICE 'PASS schedule [rate-driven]: date=%, months=%', v_result->>'target_date', v_result->>'months';

  -- TEST 3: Aufrunden bei nicht-glatter Teilung — 1000 EUR bei 300/Monat -> ceil(3.33)=4 Monate
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 1000, 'monthly_savings_rate', 300, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'months')::int IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL schedule [ceil]: erwartet 4 Monate, got %', v_result->>'months';
  END IF;
  RAISE NOTICE 'PASS schedule [ceil]: months=%', v_result->>'months';

  -- TEST 4: weder Datum noch Rate -> {ok:false}
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 5000, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL schedule [neither]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS schedule [neither -> ok:false]: %', v_result->>'reason';

  -- TEST 5: Zieldatum nicht nach first_payment -> {ok:false}
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 5000, 'target_date', '2027-01-01', 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL schedule [date<=first]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS schedule [date<=first -> ok:false]';

  -- TEST 6: Zielbetrag <= 0 -> {ok:false}
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 0, 'target_date', '2028-01-01', 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL schedule [target<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS schedule [target<=0 -> ok:false]';

  -- TEST 7 (Audit Paket 2, Punkt 15): 1000 EUR in 3 Monaten -> Rate auf den Cent AUFGERUNDET (333.34, nicht
  -- 333.33): 3 Raten = 1000.02 >= Ziel -> "erreicht" feuert (vorher 999.99, nie erreicht).
  SELECT finance.fn_savings_rate_schedule(jsonb_build_object(
    'target_amount', 1000, 'target_date', '2027-04-01', 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'monthly_rate')::numeric IS DISTINCT FROM 333.34 OR (v_result->>'months')::int IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL schedule [aufrunden]: erwartet 333.34 bei 3 Monaten, got %', v_result;
  END IF;
  IF 3 * (v_result->>'monthly_rate')::numeric < 1000 THEN
    RAISE EXCEPTION 'FAIL schedule [Ziel erreichbar]: 3 Raten < 1000';
  END IF;
  RAISE NOTICE 'PASS schedule [1000/3 -> 333.34, Raten erreichen das Ziel]';

END $$;

ROLLBACK;
