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

-- WP2 (weniger Rueckfragen): ohne first_payment_date gilt der naechste Termin des Abbuchungstags ab heute, ohne Tag heute.
DO $$
DECLARE v JSONB; v_exp DATE;
BEGIN
  v := finance.fn_savings_rate_schedule('{"target_amount":1200,"monthly_savings_rate":100}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'first_payment_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL schedule [Default ohne Tag]: heute erwartet, got %', v; END IF;
  v_exp := CASE WHEN extract(day FROM core.fn_today()) <= 15
                THEN date_trunc('month', core.fn_today())::date + 14
                ELSE (date_trunc('month', core.fn_today()) + interval '1 month')::date + 14 END;
  v := finance.fn_savings_rate_schedule('{"target_amount":1200,"monthly_savings_rate":100,"schedule_day_of_month":15}'::jsonb);
  IF (v->>'first_payment_date')::date IS DISTINCT FROM v_exp THEN
    RAISE EXCEPTION 'FAIL schedule [Default Tag 15]: % erwartet, got %', v_exp, v; END IF;
  RAISE NOTICE 'PASS schedule [erste Rate ohne Datum: heute bzw. naechster 15.]';
END $$;

-- already_saved (Sparziel-Zweckbindung 2026-10-27): gerechnet wird auf dem REST.
--  (A1) Ziel 3000, schon 1200, Datum: Rate = 1800 / Monate
--  (A2) Ziel 3000, schon 3000, Datum in der Zukunft: Rate 0, months 0, ok
--  (A3) gedeckt, aber kein Datum -> ok:false (Zieldatum ist Pflicht)
--  (A4) gedeckt, Datum in der Vergangenheit -> ok:false
--  (A5) Raten-Modus: Ziel 3000, schon 1000, Rate 500 -> 4 Monate
DO $$
DECLARE v jsonb;
BEGIN
  v := finance.fn_savings_rate_schedule('{"target_amount":3000,"already_saved":1200,"target_date":"2027-07-01","first_payment_date":"2026-11-01"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 225 THEN
    RAISE EXCEPTION 'FAIL schedule [A1 Rest]: %', v; END IF;   -- 8 Monate, 1800/8 = 225
  v := finance.fn_savings_rate_schedule(jsonb_build_object('target_amount',3000,'already_saved',3000,'target_date',(core.fn_today() + 90)::text));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'monthly_rate')::numeric IS DISTINCT FROM 0 OR (v->>'months')::int IS DISTINCT FROM 0
     OR (v->>'target_date')::date IS DISTINCT FROM core.fn_today() + 90 THEN
    RAISE EXCEPTION 'FAIL schedule [A2 gedeckt]: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":3000,"already_saved":3500,"monthly_savings_rate":100}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL schedule [A3 ohne Datum]: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":3000,"already_saved":3000,"target_date":"2020-01-01"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL schedule [A4 Vergangenheit]: %', v; END IF;
  v := finance.fn_savings_rate_schedule('{"target_amount":3000,"already_saved":1000,"monthly_savings_rate":500,"first_payment_date":"2026-11-01"}'::jsonb);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'months')::int IS DISTINCT FROM 4 OR (v->>'target_date')::date IS DISTINCT FROM DATE '2027-03-01' THEN
    RAISE EXCEPTION 'FAIL schedule [A5 Raten-Modus Rest]: %', v; END IF;
  RAISE NOTICE 'PASS schedule [already_saved: Rest-Rate, gedeckt = Rate 0, Datum Pflicht/Zukunft, Raten-Modus auf dem Rest]';
END $$;
ROLLBACK;
