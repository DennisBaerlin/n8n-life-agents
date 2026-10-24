-- tests/db/finance/test_fn_holding_symbol.sql
-- fn_holding_symbol: Kennung einer Depot-Position = Ticker, sonst ISIN (Owner-Befund 2026-10-23: Vermoegensuebersicht
-- druckt nur die ISIN). Plus der Konsument fn_book_stock_buy: ISIN ohne Ticker bucht, weder noch -> {ok:false}.
BEGIN;

DO $$
DECLARE v_settle INT; v_depot INT; v_crypto INT; v_r JSONB; v_h RECORD;
BEGIN
  IF finance.fn_holding_symbol('VWCE', 'IE00BK5BQT80') IS DISTINCT FROM 'VWCE'
     OR finance.fn_holding_symbol(' ', 'IE00BK5BQT80') IS DISTINCT FROM 'IE00BK5BQT80'
     OR finance.fn_holding_symbol(NULL, ' IE00BYML9W36 ') IS DISTINCT FROM 'IE00BYML9W36'
     OR finance.fn_holding_symbol('BTC', NULL) IS DISTINCT FROM 'BTC'
     OR finance.fn_holding_symbol('', '') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_holding_symbol Grundfaelle';
  END IF;
  RAISE NOTICE 'PASS fn_holding_symbol [Ticker > ISIN > NULL]';

  v_settle := (finance.fn_create_account('{"name":"__t_hs_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__t_hs_depot__','account_type','stocks_depot',
                'settlement_id', v_settle))->>'account_id')::int;
  v_crypto := (finance.fn_create_account(jsonb_build_object('name','__t_hs_crypto__','account_type','crypto_depot',
                'settlement_id', v_settle))->>'account_id')::int;

  -- ISIN ohne Ticker und ohne Name -> Holding mit symbol = name = ISIN, Buchungstext ohne NULL
  v_r := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
           'isin', 'IE00BYML9W36', 'shares', 2, 'price_per_share', 50, 'existing_position', true));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL book ISIN-only: %', v_r; END IF;
  SELECT symbol, name INTO v_h FROM finance.depot_holdings WHERE id = (v_r->>'holding_id')::int;
  IF v_h.symbol IS DISTINCT FROM 'IE00BYML9W36' OR v_h.name IS DISTINCT FROM 'IE00BYML9W36' THEN
    RAISE EXCEPTION 'FAIL book ISIN-only Kennung: %', row_to_json(v_h); END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_settle AND description IS NULL) THEN
    RAISE EXCEPTION 'FAIL book ISIN-only: Buchungstext NULL'; END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [ISIN ohne Ticker -> Kennung ISIN]';

  -- weder Ticker noch ISIN (Krypto ohne Symbol) -> korrigierbar {ok:false}, kein RAISE
  v_r := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_crypto, 'settlement_id', v_settle,
           'shares', 1, 'price_per_share', 10));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%ticker symbol or an ISIN%' THEN
    RAISE EXCEPTION 'FAIL book ohne Kennung: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [ohne Ticker und ISIN -> ok:false]';

  -- zweiter Konsument (Review 2026-10-23): Sparplan auf eine ISIN-only-Position -> Kennung ISIN, kein Ticker noetig
  v_r := finance.fn_create_savings_plan(jsonb_build_object('name', '__t_hs_plan__', 'depot_name', '__t_hs_depot__',
           'isin', 'IE00BYML9W36', 'security_name', 'S&P 500 (Dist)', 'amount', 25, 'first_payment_date', '2027-01-01'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT symbol FROM finance.savings_plans WHERE id = (v_r->>'savings_plan_id')::int) IS DISTINCT FROM 'IE00BYML9W36' THEN
    RAISE EXCEPTION 'FAIL create_savings_plan ISIN-only: %', v_r; END IF;
  v_r := finance.fn_create_savings_plan(jsonb_build_object('name', '__t_hs_plan2__', 'depot_name', '__t_hs_crypto__',
           'security_name', 'X', 'amount', 25, 'first_payment_date', '2027-01-01'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%ticker symbol or an ISIN%' THEN
    RAISE EXCEPTION 'FAIL create_savings_plan ohne Kennung: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [ISIN ohne Ticker -> Kennung ISIN; ohne beides -> ok:false]';
END $$;

ROLLBACK;
