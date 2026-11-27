-- tests/db/finance/test_role_finance_bookings.sql
-- Rollen-Perspektive der Buchungs-Werkzeuge: finance.fn_book_transaction, fn_book_transfer, fn_void_transaction,
--   fn_void_bank_statement, fn_book_dividend, fn_book_stock_buy, fn_book_stock_sell, fn_set_holding, fn_delete_holding
--   (je Probelauf ueber core.fn_dry_run, dann echter Write) sowie die Lese-/Helfer-fns fn_find_holding, fn_feed_symbol,
--   fn_unit_price_from_total, fn_import_depot_currency und der Cron-Write fn_upsert_market_prices laufen unter finance_rw.
--   Fixture (Konten, Positionen, Buchungen) entsteht als Superuser; im Rollen-Segment steht nur der Aufruf der fn.
--   Geprueft wird die Wirkung (Zeilen, Salden, Stueckzahlen), damit fehlende Tabellen-/Sequenz-/EXECUTE-Rechte auffallen.
BEGIN;

-- fn_book_transaction: Einzelbuchung gegen externe Gegenseite -> eine Zeile, Saldo = -42.50
DO $$
DECLARE
  r jsonb; v_a int; v_p jsonb;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__rb_tx_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_p := jsonb_build_object('account_id', v_a, 'amount', 42.5, 'direction', 'outflow', 'description', 'Erika Einkauf',
                            'transaction_date', CURRENT_DATE::text);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_transaction(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_book_transaction Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_transaction(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'amount')::numeric IS DISTINCT FROM -42.5
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_a) IS DISTINCT FROM -42.5
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (r->>'tx_id')::int AND account_id = v_a AND amount = -42.5)
  THEN RAISE EXCEPTION 'FAIL [fn_book_transaction Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_book_transaction finance_rw';
END $$;

-- fn_book_transfer: zwei Beine mit gemeinsamer group_id, Salden -300 / +300
DO $$
DECLARE
  r jsonb; v_f int; v_t int; v_p jsonb;
BEGIN
  v_f := (finance.fn_create_account('{"name":"__rb_tf_from__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_t := (finance.fn_create_account('{"name":"__rb_tf_to__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_p := jsonb_build_object('from_account_id', v_f, 'to_account_id', v_t, 'from_amount', 300, 'transaction_date', CURRENT_DATE::text,
                            'from_account_name', '__rb_tf_from__', 'to_account_name', '__rb_tf_to__', 'purpose', 'Max Taschengeld');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_transfer(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id IN (v_f, v_t)) THEN
    RAISE EXCEPTION 'FAIL [fn_book_transfer Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_transfer(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_f) IS DISTINCT FROM -300
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_t) IS DISTINCT FROM 300
     OR (SELECT count(DISTINCT group_id) FROM finance.transactions WHERE id IN ((r->>'debit_tx_id')::int, (r->>'credit_tx_id')::int)) <> 1
     OR (SELECT count(*) FROM finance.transactions WHERE category = 'transfer' AND account_id IN (v_f, v_t)) <> 2
  THEN RAISE EXCEPTION 'FAIL [fn_book_transfer Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_book_transfer finance_rw';
END $$;

-- fn_void_transaction: Fehlbuchung loeschen -> Zeile weg, Saldo wieder 0
DO $$
DECLARE
  r jsonb; v_a int; v_tx int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__rb_void_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_tx := (finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', 80, 'direction', 'inflow',
             'description', 'Erika Erstattung', 'transaction_date', CURRENT_DATE::text))->>'tx_id')::int;
  IF (SELECT balance FROM finance.account_balances WHERE account_id = v_a) IS DISTINCT FROM 80 THEN
    RAISE EXCEPTION 'FAIL [fn_void_transaction Fixture]: Saldo vor dem Void <> 80'; END IF;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_void_transaction(jsonb)'::regprocedure, jsonb_build_object('transaction_id', v_tx));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = v_tx) THEN
    RAISE EXCEPTION 'FAIL [fn_void_transaction Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'deleted_count')::int IS DISTINCT FROM 1
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE id = v_tx)
     OR COALESCE((SELECT balance FROM finance.account_balances WHERE account_id = v_a), 0) IS DISTINCT FROM 0
     OR (r->'accounts'->0->>'change')::numeric IS DISTINCT FROM -80
     OR NOT EXISTS (SELECT 1 FROM finance.transaction_audit WHERE transaction_id = v_tx)
  THEN RAISE EXCEPTION 'FAIL [fn_void_transaction Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_void_transaction finance_rw';
END $$;

-- fn_void_bank_statement: letzten Auszug zuruecknehmen -> Auszug und seine Buchung weg, Saldo 0
DO $$
DECLARE
  r jsonb; v_a int; v_prep jsonb; v_stmt jsonb;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__rb_stmt_giro__","account_type":"cash","currency":"EUR","account_number":"DE02100100100006820101"}'::jsonb)->>'account_id')::int;
  v_stmt := jsonb_build_object('account_number', 'DE02100100100006820101', 'currency', 'EUR',
              'period_start', CURRENT_DATE - 40, 'period_end', CURRENT_DATE - 10, 'opening_balance', 0, 'closing_balance', -12.5,
              'lines', jsonb_build_array(jsonb_build_object('date', CURRENT_DATE - 20, 'amount', -12.5, 'counterparty', 'Bäckerei Erika')));
  v_prep := finance.fn_statement_prepare(v_stmt);
  r := finance.fn_apply_bank_statement(v_stmt || jsonb_build_object('fingerprint', v_prep->>'fingerprint'));
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_a) IS DISTINCT FROM -12.5
     OR NOT EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_void_bank_statement Fixture]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_void_bank_statement(jsonb)'::regprocedure, jsonb_build_object('account_id', v_a));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_a) THEN
    RAISE EXCEPTION 'FAIL [fn_void_bank_statement Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_void_bank_statement(jsonb_build_object('account_id', v_a));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'voided_tx_count')::int IS DISTINCT FROM 1
     OR EXISTS (SELECT 1 FROM finance.bank_statements WHERE account_id = v_a)
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_a)
     OR COALESCE((SELECT balance FROM finance.account_balances WHERE account_id = v_a), 0) IS DISTINCT FROM 0
  THEN RAISE EXCEPTION 'FAIL [fn_void_bank_statement Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_void_bank_statement finance_rw';
END $$;

-- fn_book_stock_buy: Position anlegen + Kauf -> 10 Stueck, Einstand 80,50 (5 EUR Gebuehr gefaltet), Verrechnung -805
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_p jsonb;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_buy_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_buy_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  v_p := jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
           'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'Welt-ETF Max', 'shares', 10, 'price_per_share', 80,
           'order_fee', 5, 'transaction_date', CURRENT_DATE::text);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_stock_buy(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE account_id = v_d) THEN
    RAISE EXCEPTION 'FAIL [fn_book_stock_buy Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_stock_buy(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'total_shares')::numeric IS DISTINCT FROM 10
     OR (r->>'avg_purchase_price')::numeric IS DISTINCT FROM 80.5
     OR (SELECT shares FROM finance.depot_holdings WHERE id = (r->>'holding_id')::int) IS DISTINCT FROM 10
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_s) IS DISTINCT FROM -805
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (r->>'buy_tx_id')::int AND category = 'buy' AND amount = -805 AND shares = 10)
  THEN RAISE EXCEPTION 'FAIL [fn_book_stock_buy Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy finance_rw';
END $$;

-- fn_book_stock_sell: Verkauf von 4 von 10 Stueck @ 90, 3 EUR Gebuehr -> Erloes 357, Rest 6, Verrechnung -805 + 357
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_h int; v_p jsonb;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_sell_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_sell_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
            'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'Welt-ETF Erika', 'shares', 10, 'price_per_share', 80,
            'order_fee', 5, 'transaction_date', CURRENT_DATE::text))->>'holding_id')::int;
  v_p := jsonb_build_object('price_currency_confirmed', true, 'settlement_id', v_s, 'holding_id', v_h, 'symbol', 'IWDA',
           'shares', 4, 'price_per_share', 90, 'order_fee', 3, 'transaction_date', CURRENT_DATE::text);

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_stock_sell(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT shares FROM finance.depot_holdings WHERE id = v_h) IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'FAIL [fn_book_stock_sell Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_stock_sell(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'proceeds')::numeric IS DISTINCT FROM 357
     OR (r->>'remaining_shares')::numeric IS DISTINCT FROM 6
     OR (SELECT shares FROM finance.depot_holdings WHERE id = v_h) IS DISTINCT FROM 6
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_s) IS DISTINCT FROM -448
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (r->>'sell_tx_id')::int AND category = 'sell' AND amount = 357 AND shares = -4)
  THEN RAISE EXCEPTION 'FAIL [fn_book_stock_sell Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell finance_rw';
END $$;

-- fn_book_dividend: Ausschuettung aufs Verrechnungskonto -> Buchung category dividend, Saldo +12,50
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_h int; v_p jsonb;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_div_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_div_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
            'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'Welt-ETF Max', 'shares', 2, 'price_per_share', 100,
            'order_fee', 0, 'transaction_date', CURRENT_DATE::text))->>'holding_id')::int;
  v_p := jsonb_build_object('account_id', v_s, 'holding_id', v_h, 'amount', 12.5, 'transaction_date', CURRENT_DATE::text,
                            'description', 'Dividende Welt-ETF');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_dividend(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_s AND category = 'dividend') THEN
    RAISE EXCEPTION 'FAIL [fn_book_dividend Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_dividend(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (r->>'transaction_id')::int AND category = 'dividend'
                    AND amount = 12.5 AND holding_id = v_h)
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_s) IS DISTINCT FROM -187.5
     OR (r->>'account_balance')::numeric IS DISTINCT FROM -187.5
  THEN RAISE EXCEPTION 'FAIL [fn_book_dividend Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_book_dividend finance_rw';
END $$;

-- fn_set_holding: Metadaten einer Position aendern (Name, Anlageklasse); Stueckzahl bleibt unberuehrt
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_h int; v_p jsonb;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_set_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_set_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
            'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'Welt-ETF alt', 'shares', 3, 'price_per_share', 100,
            'order_fee', 0, 'transaction_date', CURRENT_DATE::text))->>'holding_id')::int;
  v_p := jsonb_build_object('holding_id', v_h, 'name', 'Welt-ETF Erika', 'asset_class', 'world', 'provider_symbol', 'IWDA.AS');

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_holding(jsonb)'::regprocedure, v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT name FROM finance.depot_holdings WHERE id = v_h) IS DISTINCT FROM 'Welt-ETF alt' THEN
    RAISE EXCEPTION 'FAIL [fn_set_holding Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_holding(v_p);
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM finance.depot_holdings WHERE id = v_h AND name = 'Welt-ETF Erika' AND asset_class = 'world'
                    AND provider_symbol = 'IWDA.AS' AND shares = 3 AND average_purchase_price = 100)
  THEN RAISE EXCEPTION 'FAIL [fn_set_holding Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_holding finance_rw';
END $$;

-- fn_delete_holding: leere Position (keine Buchungen) loeschen -> Zeile weg
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_h int;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_del_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_del_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency)
  VALUES (v_d, 'IE00BK5BQT80', 'VWCE', 'Fehlanlage Max', 0, 'EUR') RETURNING id INTO v_h;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_delete_holding(jsonb)'::regprocedure, jsonb_build_object('holding_id', v_h));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.depot_holdings WHERE id = v_h) THEN
    RAISE EXCEPTION 'FAIL [fn_delete_holding Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_delete_holding(jsonb_build_object('holding_id', v_h));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted'
     OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE id = v_h)
  THEN RAISE EXCEPTION 'FAIL [fn_delete_holding Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_delete_holding finance_rw';
END $$;

-- fn_find_holding: Position per Depot-Name + Symbol -> holding_id, Verrechnungskonto, Stueckzahl aus der Fixture
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_h int;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_find_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_find_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
            'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'Welt-ETF Max', 'shares', 3, 'price_per_share', 100,
            'order_fee', 0, 'transaction_date', CURRENT_DATE::text))->>'holding_id')::int;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_find_holding(jsonb_build_object('depot_name', '__rb_find_depot__', 'symbol', 'iwda'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'holding_id')::int IS DISTINCT FROM v_h
     OR (r->>'depot_id')::int IS DISTINCT FROM v_d OR (r->>'settlement_account_id')::int IS DISTINCT FROM v_s
     OR (r->>'available_shares')::numeric IS DISTINCT FROM 3
  THEN RAISE EXCEPTION 'FAIL [fn_find_holding Read finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_find_holding finance_rw';
END $$;

-- fn_feed_symbol: Aktie mit ISIN = provider_symbol sonst Symbol; Krypto ohne ISIN = Symbol-EUR
DO $$
DECLARE
  v_stock text; v_stock_override text; v_crypto text;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_stock          := finance.fn_feed_symbol('IE00B4L5Y983', 'IWDA', NULL);
  v_stock_override := finance.fn_feed_symbol('IE00B4L5Y983', 'IWDA', 'IWDA.AS');
  v_crypto         := finance.fn_feed_symbol(NULL, 'BTC', NULL);
  RESET ROLE;
  IF v_stock IS DISTINCT FROM 'IWDA' OR v_stock_override IS DISTINCT FROM 'IWDA.AS' OR v_crypto IS DISTINCT FROM 'BTC-EUR' THEN
    RAISE EXCEPTION 'FAIL [fn_feed_symbol Read finance_rw]: %, %, %', v_stock, v_stock_override, v_crypto; END IF;
  RAISE NOTICE 'PASS fn_feed_symbol finance_rw';
END $$;

-- fn_unit_price_from_total: Gesamt-Einstand / Stueck auf 8 Stellen; ohne Stueck NULL
DO $$
DECLARE
  v_even numeric; v_odd numeric; v_none numeric;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_even := finance.fn_unit_price_from_total(1000, 8);
  v_odd  := finance.fn_unit_price_from_total(100, 3);
  v_none := finance.fn_unit_price_from_total(100, 0);
  RESET ROLE;
  IF v_even IS DISTINCT FROM 125 OR v_odd IS DISTINCT FROM 33.33333333 OR v_none IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [fn_unit_price_from_total Read finance_rw]: %, %, %', v_even, v_odd, v_none; END IF;
  RAISE NOTICE 'PASS fn_unit_price_from_total finance_rw';
END $$;

-- fn_upsert_market_prices: nur gehaltenes Symbol bekommt einen Kurs; gefetchte Waehrung (USD) gewinnt und wird registriert
DO $$
DECLARE
  r jsonb; v_s int; v_d int; v_as_of date := CURRENT_DATE;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__rb_px_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_d := (finance.fn_create_account(jsonb_build_object('name','__rb_px_depot__','account_type','stocks_depot','currency','EUR','settlement_id',v_s))->>'account_id')::int;
  PERFORM finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_d, 'settlement_id', v_s,
            'isin', 'IE00BK5BQT80', 'symbol', 'RBPX', 'name', 'Test-ETF Erika', 'shares', 5, 'price_per_share', 100,
            'order_fee', 0, 'transaction_date', CURRENT_DATE::text));

  SET LOCAL ROLE finance_rw;
  r := finance.fn_upsert_market_prices(jsonb_build_object('as_of', v_as_of::text,
         'prices', jsonb_build_object('RBPX', 110.5, 'NICHTGEHALTEN', 9),
         'currencies', jsonb_build_object('RBPX', 'USD')));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'upserted')::int IS DISTINCT FROM 1
     OR NOT EXISTS (SELECT 1 FROM finance.market_prices WHERE symbol = 'RBPX' AND as_of = v_as_of AND price = 110.5 AND currency = 'USD')
     OR EXISTS (SELECT 1 FROM finance.market_prices WHERE symbol = 'NICHTGEHALTEN')
  THEN RAISE EXCEPTION 'FAIL [fn_upsert_market_prices Write finance_rw]: %', r; END IF;

  -- zweiter Lauf am selben Tag: Tages-Upsert ueberschreibt den Kurs (Update-Pfad der Rolle)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_upsert_market_prices(jsonb_build_object('as_of', v_as_of::text, 'prices', jsonb_build_object('RBPX', 111)));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT count(*) FROM finance.market_prices WHERE symbol = 'RBPX' AND as_of = v_as_of) <> 1
     OR (SELECT price FROM finance.market_prices WHERE symbol = 'RBPX' AND as_of = v_as_of) IS DISTINCT FROM 111
  THEN RAISE EXCEPTION 'FAIL [fn_upsert_market_prices Update finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices finance_rw';
END $$;

-- fn_import_depot_currency: Waehrung eines Depots (a) aus der Staging-Zeile desselben Batches, (b) ueber die Staging-Zeile
-- seines Verrechnungskontos, (c) ohne Staging-Zeile aus einem Bestandskonto (fn_resolve_account)
DO $$
DECLARE
  v_b uuid := gen_random_uuid(); v_direct text; v_via_settle text; v_existing text;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__rb_imp_usd_cash__","account_type":"cash","currency":"USD"}'::jsonb);
  INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload) VALUES
    (v_b, 1, 'account', '{"name":"__rb_imp_depot_usd__","account_type":"stocks_depot","currency":"USD"}'),
    (v_b, 2, 'account', '{"name":"__rb_imp_cash_usd__","account_type":"cash","currency":"USD"}'),
    (v_b, 3, 'account', '{"name":"__rb_imp_depot_settle__","account_type":"stocks_depot","settlement_account":"__rb_imp_cash_usd__"}');

  SET LOCAL ROLE finance_rw;
  v_direct := finance.fn_import_depot_currency(v_b, '__RB_IMP_DEPOT_USD__');
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_via_settle := finance.fn_import_depot_currency(v_b, '__rb_imp_depot_settle__');
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_existing := finance.fn_import_depot_currency(v_b, '__rb_imp_usd_cash__');
  RESET ROLE;
  IF v_direct IS DISTINCT FROM 'USD' OR v_via_settle IS DISTINCT FROM 'USD' OR v_existing IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [fn_import_depot_currency Read finance_rw]: direkt=%, ueber Verrechnungskonto=%, Bestandskonto=%',
      v_direct, v_via_settle, v_existing; END IF;
  RAISE NOTICE 'PASS fn_import_depot_currency finance_rw';
END $$;

ROLLBACK;
