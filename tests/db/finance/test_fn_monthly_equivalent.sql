-- ============================================================
-- test_fn_monthly_equivalent — zentrale Monats-Normalisierung (Single Source of Truth)
--   Deckt Praezision UND Richtung ab (die alte Formel invertierte day/week).
--   dpm = 30.4375. Erwartet: month=amount, year=amount/12, week=amount*dpm/7, day=amount*dpm.
--   Plus: die GENERATED-Spalte finance_recurring_payments.monthly_equivalent nutzt die fn.
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_acc INT;
    v_me  NUMERIC;
BEGIN
    -- dpm-Konstante
    IF finance.fn_days_per_month() <> 30.4375 THEN
        RAISE EXCEPTION 'FAIL: fn_days_per_month erwartet 30.4375, got %', finance.fn_days_per_month();
    END IF;

    -- month: amount unveraendert
    IF finance.fn_monthly_equivalent(3000, 1, 'month') <> 3000.00 THEN
        RAISE EXCEPTION 'FAIL: month 3000 -> %, erwartet 3000.00', finance.fn_monthly_equivalent(3000, 1, 'month');
    END IF;
    -- year: amount/12
    IF finance.fn_monthly_equivalent(1200, 1, 'year') <> 100.00 THEN
        RAISE EXCEPTION 'FAIL: year 1200 -> %, erwartet 100.00', finance.fn_monthly_equivalent(1200, 1, 'year');
    END IF;
    -- week: amount*30.4375/7 (RICHTUNG: groesser als amount, nicht kleiner!)
    IF finance.fn_monthly_equivalent(100, 1, 'week') <> ROUND(100 * 30.4375 / 7, 2) THEN
        RAISE EXCEPTION 'FAIL: week 100 -> %, erwartet %', finance.fn_monthly_equivalent(100, 1, 'week'), ROUND(100*30.4375/7, 2);
    END IF;
    -- day: amount*30.4375
    IF finance.fn_monthly_equivalent(30, 1, 'day') <> ROUND(30 * 30.4375, 2) THEN
        RAISE EXCEPTION 'FAIL: day 30 -> %, erwartet %', finance.fn_monthly_equivalent(30, 1, 'day'), ROUND(30*30.4375, 2);
    END IF;
    -- biweekly (interval=2, week)
    IF finance.fn_monthly_equivalent(100, 2, 'week') <> ROUND(100 * 30.4375 / 14, 2) THEN
        RAISE EXCEPTION 'FAIL: biweekly 100 -> %, erwartet %', finance.fn_monthly_equivalent(100, 2, 'week'), ROUND(100*30.4375/14, 2);
    END IF;

    -- GENERATED-Spalte nutzt die fn: weekly Recurring Payment
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__test_me_acc__', 'cash', 'EUR', 'active') RETURNING id INTO v_acc;
    INSERT INTO finance.recurring_payments
        (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from)
    VALUES ('__test_me_weekly__', v_acc, -25, 1, 'week', CURRENT_DATE, CURRENT_DATE);
    SELECT monthly_equivalent INTO v_me FROM finance.recurring_payments WHERE name = '__test_me_weekly__';
    IF v_me <> ROUND(-25 * 30.4375 / 7, 2) THEN
        RAISE EXCEPTION 'FAIL: GENERATED monthly_equivalent weekly -25 -> %, erwartet %', v_me, ROUND(-25*30.4375/7, 2);
    END IF;

    -- Feste Monatstage (4-arg-Form): 4 Termine je Monat = 4x Betrag (Broker-Kalender 2/9/16/23), alle 2 Monate = halb
    IF finance.fn_monthly_equivalent(100, 1, 'month', 4) <> 400.00 THEN
        RAISE EXCEPTION 'FAIL: 4 Tage/Monat 100 -> %, erwartet 400.00', finance.fn_monthly_equivalent(100, 1, 'month', 4);
    END IF;
    IF finance.fn_monthly_equivalent(100, 2, 'month', 2) <> 100.00 THEN
        RAISE EXCEPTION 'FAIL: 2 Tage alle 2 Monate 100 -> %, erwartet 100.00', finance.fn_monthly_equivalent(100, 2, 'month', 2);
    END IF;

    -- GENERATED-Spalte zaehlt die Tage: 4 feste Monatstage x -100 = -400 (nicht -100 * 30.4375/7)
    INSERT INTO finance.recurring_payments
        (name, account_id, amount, schedule_interval, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
    VALUES ('__test_me_days__', v_acc, -100, 1, 'month', '{2,9,16,23}', CURRENT_DATE, CURRENT_DATE);
    SELECT monthly_equivalent INTO v_me FROM finance.recurring_payments WHERE name = '__test_me_days__';
    IF v_me <> -400.00 THEN
        RAISE EXCEPTION 'FAIL: GENERATED monthly_equivalent 4 Tage -100 -> %, erwartet -400.00', v_me;
    END IF;

    RAISE NOTICE 'PASS test_fn_monthly_equivalent (dpm + day/week/month/year + feste Monatstage + GENERATED-Spalte)';
END $$;
ROLLBACK;
