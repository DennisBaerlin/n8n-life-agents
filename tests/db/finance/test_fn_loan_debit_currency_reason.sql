-- tests/db/finance/test_fn_loan_debit_currency_reason.sql
-- fn_loan_debit_currency_reason: gleiche Waehrung -> NULL, andere Waehrung -> reason mit beiden Waehrungen,
-- unbekanntes Konto -> NULL.
BEGIN;

DO $$
DECLARE v_eur INT; v_eur2 INT; v_usd INT; v_r TEXT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_ldc_eur__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_eur;
  SELECT (finance.fn_create_account('{"name":"__test_ldc_eur2__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_eur2;
  SELECT (finance.fn_create_account('{"name":"__test_ldc_usd__","account_type":"cash","currency":"USD"}'::jsonb)->>'account_id')::int INTO v_usd;
  IF finance.fn_loan_debit_currency_reason(v_eur, v_eur2) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL loan_currency [gleich]: erwartet NULL'; END IF;
  v_r := finance.fn_loan_debit_currency_reason(v_usd, v_eur);
  IF v_r IS NULL OR v_r NOT LIKE '%USD%' OR v_r NOT LIKE '%EUR%' THEN
    RAISE EXCEPTION 'FAIL loan_currency [USD gegen EUR]: got %', v_r; END IF;
  IF finance.fn_loan_debit_currency_reason(-1, v_eur) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL loan_currency [unbekannt]: erwartet NULL'; END IF;
  RAISE NOTICE 'PASS loan_currency [gleich NULL, fremd reason, unbekannt NULL]';
END $$;

ROLLBACK;
