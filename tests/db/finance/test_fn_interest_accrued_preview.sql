-- tests/db/finance/test_fn_interest_accrued_preview.sql
-- Aufgelaufener, noch nicht gebuchter Zins (Schaetzwert): basis x Satz x day_fraction(aufzins_start, as_of, conv).
-- aufzins_start = letztes gebuchtes Scheduler-Perioden-Ende, sonst Zins-Start MIN(valid_from). Read-only.
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_acct INT;
  v_amt  NUMERIC;
BEGIN
  -- 3.65% jaehrlich cash (fn_create_account setzt cash -> ACT/365), Einzahlung 10000 am 2026-01-01.
  SELECT finance.fn_create_account(
    '{"name":"__test_int_preview__","account_type":"cash","currency":"EUR","interest_rate":3.65,"interest_credit_unit":"year","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');

  -- noch nichts gebucht: aufgelaufen 2026-01-01..2026-01-11 (10 Tage) = 10000*3.65%*10/365 = 10.00
  v_amt := finance.fn_interest_accrued_preview(v_acct, '2026-01-11');
  IF v_amt IS DISTINCT FROM 10.00 THEN RAISE EXCEPTION 'FAIL [preview no booking]: erwartet 10.00, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [preview ohne Buchung -> 10.00 (10 Tage)]';

  -- Gutschrift fuer Periode bis 2026-01-11 buchen (10.00) -> Saldo 10010
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-01-11', 'period_end', '2026-01-11')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [preview book setup]: %', v_res; END IF;

  -- aufgelaufen ab dem letzten Perioden-Ende 2026-01-11 bis 2026-01-21 (10 Tage), basis 10010 (Gutschrift zaehlt)
  --   = 10010 * 3.65% * 10/365 = 10.01 (Zinseszins ueber die gebuchte Gutschrift)
  v_amt := finance.fn_interest_accrued_preview(v_acct, '2026-01-21');
  IF v_amt IS DISTINCT FROM 10.01 THEN RAISE EXCEPTION 'FAIL [preview after booking]: erwartet 10.01, got %', v_amt; END IF;
  RAISE NOTICE 'PASS [preview nach Buchung -> 10.01 (ab letztem Perioden-Ende, basis inkl. Gutschrift)]';

  -- as_of = letztes Perioden-Ende -> seit der Gutschrift nichts aufgelaufen -> 0
  IF finance.fn_interest_accrued_preview(v_acct, '2026-01-11') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [preview at last credit]: erwartet 0';
  END IF;
  RAISE NOTICE 'PASS [preview am letzten Perioden-Ende -> 0]';

  -- Konto ohne Zinssatz -> 0
  SELECT finance.fn_create_account('{"name":"__test_int_prev_norate__","account_type":"cash"}'::jsonb) INTO v_res;
  IF finance.fn_interest_accrued_preview((v_res->>'account_id')::int, '2026-06-01') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [preview no rate]: erwartet 0';
  END IF;
  RAISE NOTICE 'PASS [preview ohne Zinssatz -> 0]';

  -- Nullsaldo -> 0
  SELECT finance.fn_create_account(
    '{"name":"__test_int_prev_zero__","account_type":"cash","interest_rate":4,"interest_credit_unit":"year","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  IF finance.fn_interest_accrued_preview((v_res->>'account_id')::int, '2026-06-01') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [preview zero balance]: erwartet 0';
  END IF;
  RAISE NOTICE 'PASS [preview Nullsaldo -> 0]';
END $$;

ROLLBACK;
