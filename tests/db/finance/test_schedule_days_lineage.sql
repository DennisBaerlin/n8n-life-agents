-- tests/db/finance/test_schedule_days_lineage.sql
-- Feste Monatstage (recurring_payments.schedule_days_of_month) ueber die Vorgaenger-Kette: Validity-Split und
-- Reaktivieren erben die Tage (vorher kam ein 4-Tage-Plan still als 1x/Monat zurueck = falsche Rate), ein
-- Einzeltag oder eine andere Einheit leert sie (Tage + Einzeltag waere ein CHECK-RAISE = Owner-Alarm).
BEGIN;

DO $$
DECLARE
  v_acct INT; v_rp INT; v_new INT; v_res JSONB;
  v_r finance.recurring_payments%ROWTYPE;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__sdl_acct__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;

  -- Betrags-Split: Tage geerbt, Anker bleibt
  v_rp := finance.fn_add_recurring_payment(v_acct, -100, '__sdl_a__', 1::smallint, 'month'::finance.schedule_unit, NULL,
            DATE '2026-01-02', DATE '2026-01-02', NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,9,16,23}' WHERE id = v_rp;
  v_res := finance.fn_split_recurring_payment(v_rp, DATE '2026-03-01', -150, NULL, NULL, NULL, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [split amount]: %', v_res; END IF;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{2,9,16,23}'::smallint[] OR v_r.monthly_equivalent <> -600.00
     OR v_r.first_payment_date <> DATE '2026-01-02' THEN
    RAISE EXCEPTION 'FAIL [split amount]: days=% me=% anchor=%', v_r.schedule_days_of_month, v_r.monthly_equivalent, v_r.first_payment_date; END IF;
  RAISE NOTICE 'PASS [Betrags-Split erbt die Tage + Anker]';

  -- Split mit neuen Tagen: Tage ersetzt, Neu-Anker am Stichtag
  v_new := v_r.id;
  v_res := finance.fn_split_recurring_payment(v_new, DATE '2026-04-02', NULL, NULL, NULL, NULL, NULL, NULL, NULL, '{2,16}');
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [split days]: %', v_res; END IF;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{2,16}'::smallint[] OR v_r.monthly_equivalent <> -300.00
     OR v_r.first_payment_date <> DATE '2026-04-02' THEN
    RAISE EXCEPTION 'FAIL [split days]: days=% me=% anchor=%', v_r.schedule_days_of_month, v_r.monthly_equivalent, v_r.first_payment_date; END IF;
  RAISE NOTICE 'PASS [Split mit neuen Tagen]';

  -- Split auf Einzeltag: Tage geleert (kein CHECK-RAISE)
  v_new := v_r.id;
  v_res := finance.fn_split_recurring_payment(v_new, DATE '2026-05-02', NULL, NULL, NULL, 2::smallint, NULL, NULL, NULL);
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS NOT NULL OR v_r.schedule_day_of_month <> 2 OR v_r.monthly_equivalent <> -150.00 THEN
    RAISE EXCEPTION 'FAIL [split dom]: days=% dom=% me=%', v_r.schedule_days_of_month, v_r.schedule_day_of_month, v_r.monthly_equivalent; END IF;
  RAISE NOTICE 'PASS [Split auf Einzeltag leert die Tage]';

  -- Split auf Woche: Tage geleert
  v_rp := finance.fn_add_recurring_payment(v_acct, -100, '__sdl_b__', 1::smallint, 'month'::finance.schedule_unit, NULL,
            DATE '2026-01-02', DATE '2026-01-02', NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,16}' WHERE id = v_rp;
  v_res := finance.fn_split_recurring_payment(v_rp, DATE '2026-03-05', NULL, NULL, 'week'::finance.schedule_unit, NULL, NULL, NULL, NULL);
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_r.schedule_unit <> 'week' OR v_r.schedule_days_of_month IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [split week]: unit=% days=%', v_r.schedule_unit, v_r.schedule_days_of_month; END IF;
  RAISE NOTICE 'PASS [Split auf Woche leert die Tage]';

  -- Reaktivieren nach Soft-Close erbt die Tage
  v_rp := finance.fn_add_recurring_payment(v_acct, -100, '__sdl_c__', 1::smallint, 'month'::finance.schedule_unit, NULL,
            DATE '2026-01-02', DATE '2026-01-02', DATE '2026-02-01', NULL, NULL);
  UPDATE finance.recurring_payments SET schedule_days_of_month = '{2,9,16,23}' WHERE id = v_rp;
  v_res := finance.fn_reopen_recurring_payment(v_rp, DATE '2026-03-01');
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [reopen]: %', v_res; END IF;
  SELECT * INTO v_r FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_r.schedule_days_of_month IS DISTINCT FROM '{2,9,16,23}'::smallint[] OR v_r.monthly_equivalent <> -400.00 THEN
    RAISE EXCEPTION 'FAIL [reopen]: days=% me=%', v_r.schedule_days_of_month, v_r.monthly_equivalent; END IF;
  RAISE NOTICE 'PASS [Reaktivieren erbt die Tage]';
END $$;

ROLLBACK;
