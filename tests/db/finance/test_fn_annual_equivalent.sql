-- tests/db/finance/test_fn_annual_equivalent.sql
-- fn_annual_equivalent = Jahreswert eines Betrags je Abbuchung ohne Zwischenrundung (WP2: der Jahresbeitrag einer
-- Versicherung wird aus der echten Abbuchung abgeleitet, nie gespeichert). Dazu fn_period_months (Monate je Periode,
-- die eine Adresse fuer Zins-Faktor und Jahreswert).
BEGIN;

DO $$
BEGIN
  IF finance.fn_annual_equivalent(30, 1, 'month', 1) IS DISTINCT FROM 360.00 THEN
    RAISE EXCEPTION 'FAIL [monat]: %', finance.fn_annual_equivalent(30, 1, 'month', 1); END IF;
  IF finance.fn_annual_equivalent(89, 1, 'year', 1) IS DISTINCT FROM 89.00 THEN
    RAISE EXCEPTION 'FAIL [jahr]: %', finance.fn_annual_equivalent(89, 1, 'year', 1); END IF;
  IF finance.fn_annual_equivalent(60, 3, 'month', 1) IS DISTINCT FROM 240.00 THEN
    RAISE EXCEPTION 'FAIL [quartal]: %', finance.fn_annual_equivalent(60, 3, 'month', 1); END IF;
  IF finance.fn_annual_equivalent(7, 1, 'week', 1) IS DISTINCT FROM 365.25 THEN
    RAISE EXCEPTION 'FAIL [woche]: %', finance.fn_annual_equivalent(7, 1, 'week', 1); END IF;
  -- Rundungs-Drift der Ableitung (dokumentiert): 100/Jahr monatlich = 8,33 je Abbuchung -> 99,96 im Jahr
  IF finance.fn_annual_equivalent(finance.fn_insurance_period_amount(100, 1, 'month'), 1, 'month', 1) IS DISTINCT FROM 99.96 THEN
    RAISE EXCEPTION 'FAIL [drift]'; END IF;
  -- feste Monatstage: 4 Termine je Monat
  IF finance.fn_annual_equivalent(25, 1, 'month', 4) IS DISTINCT FROM 1200.00 THEN
    RAISE EXCEPTION 'FAIL [tage]'; END IF;
  IF finance.fn_period_months(3, 'month') <> 3 OR finance.fn_period_months(1, 'year') <> 12
     OR round(finance.fn_period_months(1, 'week'), 6) <> round(7 / 30.4375, 6) THEN
    RAISE EXCEPTION 'FAIL [period_months]'; END IF;
  RAISE NOTICE 'PASS fn_annual_equivalent + fn_period_months';
END $$;

ROLLBACK;
