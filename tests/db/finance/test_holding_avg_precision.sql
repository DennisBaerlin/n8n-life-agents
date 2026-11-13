-- tests/db/finance/test_holding_avg_precision.sql
-- Praezision des Durchschnittskaufpreises: depot_holdings.average_purchase_price ist numeric(20,8) wie
--   market_prices.price (numeric(12,4) rundete Mini-Kurse unter 0.0001 wie Krypto-Bruchteile und Penny-Token auf 0 bzw. 0.0001).
--   Beispiel: 1.000.000 Stueck fuer 50 EUR -> Durchschnitt 0.00005; fn_holding_avg_cost rundet auf 8 Stellen; der Buchwert in depot_holdings_overview stimmt.
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_settle INT;
  v_depot  INT;
  v_h      INT;
  v_avg    NUMERIC;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_hap_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_hap_depot__','account_type','crypto_depot',
    'currency','EUR','settlement_id',v_settle))->>'account_id')::int INTO v_depot;
  v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id',v_depot,'settlement_id',v_settle,
    'symbol','SHIBX','name','Mini Token','shares',1000000,'price_per_share',0.00005,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL buy: %', v_res; END IF;
  v_h := (v_res->>'holding_id')::int;

  SELECT average_purchase_price INTO v_avg FROM finance.depot_holdings WHERE id = v_h;
  IF v_avg IS DISTINCT FROM 0.00005 THEN
    RAISE EXCEPTION 'FAIL avg-Praezision: erwartet 0.00005, got %', v_avg; END IF;
  IF finance.fn_holding_avg_cost(v_h) IS DISTINCT FROM 0.00005 THEN
    RAISE EXCEPTION 'FAIL avg-Praezision [fn]: erwartet 0.00005, got %', finance.fn_holding_avg_cost(v_h); END IF;
  IF (SELECT book_value FROM finance.depot_holdings_overview WHERE id = v_h) IS DISTINCT FROM 50.00 THEN
    RAISE EXCEPTION 'FAIL avg-Praezision [Buchwert]: erwartet 50.00, got %',
      (SELECT book_value FROM finance.depot_holdings_overview WHERE id = v_h); END IF;
  RAISE NOTICE 'PASS avg-Praezision [1.000.000 Stueck fuer 50 EUR -> Durchschnitt 0.00005, Buchwert 50.00]';
END $$;

ROLLBACK;
