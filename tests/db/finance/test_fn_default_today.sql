-- tests/db/finance/test_fn_default_today.sql
-- "Datum leer = heute" sitzt in der DB (Paket DB-ist-das-Gesetz S5), nicht im Prompt: fn_book_transaction,
--   fn_book_transfer, fn_book_stock_buy, fn_book_stock_sell buchen ohne transaction_date auf core.fn_today()
--   (Haushalts-Zeitzone) und melden den gesetzten Wert als effective.transaction_date zurueck. Der Probelauf vor der Karte
--   reicht effective fest in den echten Write (New-FnWriteGate) -> Karte und Buchung zeigen dasselbe Datum.
--   Ein genanntes Datum bleibt unveraendert (effective traegt es ebenfalls).
BEGIN;

DO $$
DECLARE
  v_r jsonb; v_a int; v_b int; v_depot int; v_hold int; v_d date;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__dt_a__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__dt_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;

  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', '12.5', 'direction', 'outflow',
           'transaction_date', ''));
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'tx_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL default_today [book_transaction]: % / %', v_r, v_d; END IF;

  v_r := finance.fn_book_transaction(jsonb_build_object('account_id', v_a, 'amount', '1', 'direction', 'outflow',
           'transaction_date', '2026-01-15'));
  IF (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL default_today [book_transaction genanntes Datum]: %', v_r; END IF;

  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id', v_a, 'to_account_id', v_b, 'amount', 100,
           'from_account_name', '__dt_a__', 'to_account_name', '__dt_b__'));
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'debit_tx_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL default_today [book_transfer]: % / %', v_r, v_d; END IF;

  v_depot := (finance.fn_create_account(jsonb_build_object('name', '__dt_depot__', 'account_type', 'stocks_depot',
                'settlement_id', v_a))->>'account_id')::int;
  v_r := finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_a,
           'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'iShares MSCI World',
           'shares', 2, 'price_per_share', 100, 'order_fee', ''));
  v_hold := (v_r->>'holding_id')::int;
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'buy_tx_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'order_fee')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL default_today [book_stock_buy]: % / %', v_r, v_d; END IF;

  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_a, 'holding_id', v_hold,
           'shares', 1, 'price_per_share', 110, 'symbol', 'IWDA'));
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'sell_tx_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'order_fee')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL default_today [book_stock_sell]: % / %', v_r, v_d; END IF;

  -- Dividende (c9-Fund 2026-10-23: Pflicht-Datum -> das Modell erfand 2025-01-01)
  v_r := finance.fn_book_dividend(jsonb_build_object('account_id', v_a, 'amount', 4.2, 'holding_id', v_hold,
           'description', 'Dividende IWDA'));
  SELECT transaction_date INTO v_d FROM finance.transactions WHERE id = (v_r->>'transaction_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_d IS DISTINCT FROM core.fn_today()
     OR (v_r->'effective'->>'transaction_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL default_today [book_dividend]: % / %', v_r, v_d; END IF;

  -- Kontostand-Abgleich ohne Stichtag = heute (fn_reconcile_blocker prueft "Zukunft" gegen fn_today)
  v_r := finance.fn_reconcile_account(jsonb_build_object('account_id', v_b, 'confirmed_balance', 150));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->'effective'->>'reconciliation_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL default_today [reconcile_account]: %', v_r; END IF;

  -- Konto schliessen ohne Datum = heute (c9-Fund 2026-10-23: Pflicht-Datum -> das Modell erfand 2025-01-01)
  v_r := finance.fn_create_account('{"name":"__dt_close__","account_type":"cash"}'::jsonb);
  v_r := finance.fn_close_account(jsonb_build_object('account_id', (v_r->>'account_id')::int));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->'effective'->>'closure_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL default_today [close_account]: %', v_r; END IF;

  RAISE NOTICE 'PASS default_today [transaction/transfer/stock_buy/stock_sell/dividend/reconcile/close_account: leer = fn_today, effective zurueck]';
END $$;

ROLLBACK;
