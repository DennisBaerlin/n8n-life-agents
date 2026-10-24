-- tests/db/finance/test_fn_insurance_period_amount.sql
-- Testet fn_insurance_period_amount: Beitrag je Abbuchung aus der Jahrespraemie, exakte Umkehrung von
-- fn_monthly_equivalent (Monatswert jeder Kadenz = Jahrespraemie / 12).
BEGIN;

DO $$
DECLARE
  r RECORD;
BEGIN
  IF finance.fn_insurance_period_amount(1200, 1, 'year')  <> 1200   THEN RAISE EXCEPTION 'FAIL year 1200 -> %', finance.fn_insurance_period_amount(1200, 1, 'year'); END IF;
  IF finance.fn_insurance_period_amount(1200, 1, 'month') <> 100    THEN RAISE EXCEPTION 'FAIL month 1200 -> %', finance.fn_insurance_period_amount(1200, 1, 'month'); END IF;
  IF finance.fn_insurance_period_amount(1200, 3, 'month') <> 300    THEN RAISE EXCEPTION 'FAIL quarterly 1200 -> %', finance.fn_insurance_period_amount(1200, 3, 'month'); END IF;
  IF finance.fn_insurance_period_amount(1200, 6, 'month') <> 600    THEN RAISE EXCEPTION 'FAIL half-yearly 1200 -> %', finance.fn_insurance_period_amount(1200, 6, 'month'); END IF;
  IF finance.fn_insurance_period_amount(1200, 1, 'week')  <> 23.00  THEN RAISE EXCEPTION 'FAIL week 1200 -> %', finance.fn_insurance_period_amount(1200, 1, 'week'); END IF;
  IF finance.fn_insurance_period_amount(365.25, 1, 'day') <> 1.00   THEN RAISE EXCEPTION 'FAIL day 365.25 -> %', finance.fn_insurance_period_amount(365.25, 1, 'day'); END IF;
  IF finance.fn_insurance_period_amount(89.50, NULL, 'year') <> 89.50 THEN RAISE EXCEPTION 'FAIL interval NULL -> 1'; END IF;
  RAISE NOTICE 'PASS fn_insurance_period_amount [year/month/quarter/half-year/week/day + interval NULL]';

  -- Konsistenz: Monatswert der abgeleiteten Rate = Jahrespraemie / 12 (Toleranz Rundung 0.02)
  FOR r IN SELECT * FROM (VALUES (1200::numeric, 1, 'month'::finance.schedule_unit), (1200, 3, 'month'),
                                 (1200, 1, 'year'), (1200, 1, 'week'), (1200, 2, 'week'), (730.5, 1, 'day')) t(a, i, u)
  LOOP
    IF abs(finance.fn_monthly_equivalent(finance.fn_insurance_period_amount(r.a, r.i, r.u), r.i, r.u) - r.a / 12) > 0.02 THEN
      RAISE EXCEPTION 'FAIL Konsistenz % / % %: Monatswert % statt %', r.a, r.i, r.u,
        finance.fn_monthly_equivalent(finance.fn_insurance_period_amount(r.a, r.i, r.u), r.i, r.u), r.a / 12;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS fn_insurance_period_amount [Umkehrung von fn_monthly_equivalent fuer alle Kadenzen]';
END $$;

ROLLBACK;
