-- tests/db/finance/test_fn_verify_holding_shares.sql
-- Testet fn_verify_holding_shares: Self-Check nach Buy (TRUE bei korrekter, FALSE bei falscher Erwartung).
BEGIN;

DO $$
DECLARE v_settle INT; v_depot INT; v_hid INT;
BEGIN
  SELECT (finance.fn_create_account(
    '{"name":"__vh_settle__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb
  )->>'account_id')::int INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object(
    'name','__vh_depot__','account_type','stocks_depot','account_holder','T','currency','EUR','settlement_id',v_settle
  ))->>'account_id')::int INTO v_depot;

  SELECT (finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id',v_depot,'settlement_id',v_settle,'isin','VHISIN','symbol','VH','name','VH ETF',
    'shares','10','price_per_share','50','order_fee','0','transaction_date',CURRENT_DATE::text
  ))->>'holding_id')::int INTO v_hid;

  IF finance.fn_verify_holding_shares(v_hid, 10) IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'FAIL verify_holding_shares [korrekt]: erwartet TRUE bei 10';
  END IF;
  IF finance.fn_verify_holding_shares(v_hid, 5) IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FAIL verify_holding_shares [falsch]: erwartet FALSE bei 5';
  END IF;

  RAISE NOTICE 'PASS fn_verify_holding_shares: TRUE@10 + FALSE@5 (holding_id=%)', v_hid;
END $$;

ROLLBACK;
