-- tests/db/finance/test_fn_loan_period_months.sql
-- Testet fn_loan_period_months: Monate je Raten-Periode einer Kredit-rp (die eine Adresse fuer fn_get_loan_payment_split
-- und den Guard "Rate deckt den Zins" in fn_set_loan). Ohne rp = 1 Monat.
BEGIN;
DO $$
DECLARE v_acct INT; r_m INT; r_q INT; r_y INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_lpm_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_acct;
  r_m := finance.fn_add_recurring_payment(v_acct, -100, 'lpm monat', 1::smallint, 'month'::finance.schedule_unit, 1::smallint, '2026-01-01', '2026-01-01', NULL, NULL, NULL);
  r_q := finance.fn_add_recurring_payment(v_acct, -100, 'lpm quartal', 3::smallint, 'month'::finance.schedule_unit, 1::smallint, '2026-01-01', '2026-01-01', NULL, NULL, NULL);
  r_y := finance.fn_add_recurring_payment(v_acct, -100, 'lpm jahr', 1::smallint, 'year'::finance.schedule_unit, NULL, '2026-01-01', '2026-01-01', NULL, NULL, NULL);
  IF finance.fn_loan_period_months(r_m) <> 1 OR finance.fn_loan_period_months(r_q) <> 3
     OR finance.fn_loan_period_months(r_y) <> 12 OR finance.fn_loan_period_months(NULL) <> 1 THEN
    RAISE EXCEPTION 'FAIL fn_loan_period_months: % / % / % / %', finance.fn_loan_period_months(r_m),
      finance.fn_loan_period_months(r_q), finance.fn_loan_period_months(r_y), finance.fn_loan_period_months(NULL);
  END IF;
  RAISE NOTICE 'PASS fn_loan_period_months [Monat 1, Quartal 3, Jahr 12, ohne rp 1]';
END $$;
ROLLBACK;
