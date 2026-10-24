-- tests/db/finance/test_fn_get_balance.sql
-- Testet fn_get_balance: Saldo eines Kontos (nach Buchung) bzw. NULL fuer unbekanntes Konto.
BEGIN;

DO $$
DECLARE v_acct INT; v_bal NUMERIC;
BEGIN
  SELECT (finance.fn_create_account(
    '{"name":"__gb_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb
  )->>'account_id')::int INTO v_acct;

  PERFORM finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct, 'amount','100', 'direction','inflow', 'transaction_date', CURRENT_DATE::text));

  SELECT finance.fn_get_balance(v_acct) INTO v_bal;
  IF v_bal IS DISTINCT FROM 100 THEN RAISE EXCEPTION 'FAIL get_balance: erwartet 100, got %', v_bal; END IF;

  SELECT finance.fn_get_balance(999999) INTO v_bal;
  IF v_bal IS NOT NULL THEN RAISE EXCEPTION 'FAIL get_balance [unbekannt]: erwartet NULL, got %', v_bal; END IF;

  RAISE NOTICE 'PASS fn_get_balance: 100 nach Buchung + NULL fuer unbekanntes Konto';
END $$;

ROLLBACK;
