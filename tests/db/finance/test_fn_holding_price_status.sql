-- tests/db/finance/test_fn_holding_price_status.sql
-- Kurs-Luecken (2026-10-27): EINE Adresse fuer "hat diese Position einen Kurs?". Prueft:
--   (1) fn_feed_symbol: Aktie = provider_symbol sonst symbol; Krypto = provider_symbol sonst symbol||'-EUR';
--   (2) fn_price_status: NULL -> missing; genau an der Schwelle -> ok; einen Tag darueber -> stale ('>');
--   (3) fn_holding_price_status: je gehaltener Position Status/letzter Kurs/feed_symbol, Filter auf ids,
--       shares=0 faellt raus;
--   (4) depot_holdings_overview.price_status aus derselben Regel;
--   (5) finance_ro liest Status-fn + View (Rollen-Lesepfad).
BEGIN;
DO $$
DECLARE
  v_days  int := COALESCE(NULLIF(core.fn_config_get('core','advisor','price_stale_days'), '')::int, 7);
  v_cash  int; v_depot int; v_crypto int;
  v_ok int; v_stale int; v_miss int; v_btc int; v_sold int;
  r record;
  v_cnt int;
  v_txt text;
BEGIN
  -- (1) fn_feed_symbol
  IF finance.fn_feed_symbol('IE00TEST0001', 'ABC', NULL) IS DISTINCT FROM 'ABC'
     OR finance.fn_feed_symbol('IE00TEST0001', 'ABC', 'ABC.DE') IS DISTINCT FROM 'ABC.DE'
     OR finance.fn_feed_symbol(NULL, 'BTC', NULL) IS DISTINCT FROM 'BTC-EUR'
     OR finance.fn_feed_symbol(NULL, 'UNI', 'UNI7083-USD') IS DISTINCT FROM 'UNI7083-USD'
     OR finance.fn_feed_symbol('', 'ETH', '') IS DISTINCT FROM 'ETH-EUR' THEN
    RAISE EXCEPTION 'FAIL [1 feed_symbol]: Aktie/Krypto-Regel verletzt';
  END IF;
  RAISE NOTICE 'PASS fn_feed_symbol [Aktie provider->symbol, Krypto provider->symbol-EUR]';

  -- (2) fn_price_status
  IF finance.fn_price_status(NULL) <> 'missing'
     OR finance.fn_price_status(current_date) <> 'ok'
     OR finance.fn_price_status(current_date - v_days) <> 'ok'
     OR finance.fn_price_status(current_date - v_days - 1) <> 'stale' THEN
    RAISE EXCEPTION 'FAIL [2 price_status]: Schwelle % Tage, got null=% heute=% grenze=% drueber=%', v_days,
      finance.fn_price_status(NULL), finance.fn_price_status(current_date),
      finance.fn_price_status(current_date - v_days), finance.fn_price_status(current_date - v_days - 1);
  END IF;
  RAISE NOTICE 'PASS fn_price_status [missing / ok an der Grenze / stale einen Tag darueber]';

  -- (3) Holdings: ok, stale, missing, Krypto ohne Kurs, verkauft (shares 0)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__hps_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__hps_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__hps_crypto__','crypto_depot','EUR','active', v_cash) RETURNING id INTO v_crypto;

  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, provider_symbol)
  VALUES (v_depot,'IE00TEST0001','HPSOK','Fonds Ok', 2, 50, 'EUR', 'HPSOK.DE') RETURNING id INTO v_ok;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TEST0002','HPSST','Fonds Alt', 3, 40, 'EUR') RETURNING id INTO v_stale;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TEST0003','HPSMI','Fonds Ohne', 4, 30, 'EUR') RETURNING id INTO v_miss;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_crypto, NULL,'HPSC','Testcoin', 1.5, 20, 'EUR') RETURNING id INTO v_btc;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TEST0004','HPSSO','Fonds Verkauft', 0, 10, 'EUR') RETURNING id INTO v_sold;

  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('HPSOK', 55, 'EUR', current_date - 1),
    ('HPSOK', 54, 'EUR', current_date - 3),            -- aelter: darf nicht gewinnen
    ('HPSST', 41, 'EUR', current_date - v_days - 1);

  SELECT * INTO r FROM finance.fn_holding_price_status(ARRAY[v_ok]);
  IF r.status <> 'ok' OR r.price <> 55 OR r.price_as_of <> current_date - 1 OR r.feed_symbol <> 'HPSOK.DE'
     OR r.price_currency <> 'EUR' OR r.account_name <> '__hps_depot__' OR r.avg_price <> 50 THEN
    RAISE EXCEPTION 'FAIL [3 ok]: got status=% price=% as_of=% feed=% ccy=% acct=% avg=%',
      r.status, r.price, r.price_as_of, r.feed_symbol, r.price_currency, r.account_name, r.avg_price;
  END IF;
  SELECT * INTO r FROM finance.fn_holding_price_status(ARRAY[v_stale]);
  IF r.status <> 'stale' OR r.price <> 41 OR r.feed_symbol <> 'HPSST' THEN
    RAISE EXCEPTION 'FAIL [3 stale]: got status=% price=% feed=%', r.status, r.price, r.feed_symbol; END IF;
  SELECT * INTO r FROM finance.fn_holding_price_status(ARRAY[v_miss]);
  IF r.status <> 'missing' OR r.price IS NOT NULL OR r.price_as_of IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3 missing]: got status=% price=% as_of=%', r.status, r.price, r.price_as_of; END IF;
  SELECT * INTO r FROM finance.fn_holding_price_status(ARRAY[v_btc]);
  IF r.status <> 'missing' OR r.feed_symbol <> 'HPSC-EUR' OR r.isin IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3 crypto]: got status=% feed=%', r.status, r.feed_symbol; END IF;

  SELECT count(*) INTO v_cnt FROM finance.fn_holding_price_status(ARRAY[v_ok, v_stale, v_miss, v_btc, v_sold]);
  IF v_cnt <> 4 THEN
    RAISE EXCEPTION 'FAIL [3 filter]: erwartet 4 gehaltene Positionen (verkaufte raus), got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM finance.fn_holding_price_status() WHERE holding_id IN (v_ok, v_stale, v_miss, v_btc, v_sold);
  IF v_cnt <> 4 THEN
    RAISE EXCEPTION 'FAIL [3 ohne Filter]: erwartet 4, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS fn_holding_price_status [ok/stale/missing/Krypto, juengster Kurs, Filter, shares=0 raus]';

  -- (4) View-Spalte aus derselben Regel
  SELECT string_agg(price_status, ',' ORDER BY id) INTO v_txt
  FROM finance.depot_holdings_overview WHERE id IN (v_ok, v_stale, v_miss);
  IF v_txt IS DISTINCT FROM 'ok,stale,missing' THEN
    RAISE EXCEPTION 'FAIL [4 view]: erwartet ok,stale,missing, got %', v_txt; END IF;
  RAISE NOTICE 'PASS depot_holdings_overview.price_status [ok,stale,missing]';

  -- (5) finance_ro liest Status-fn + View
  SET LOCAL ROLE finance_ro;
  SELECT count(*) INTO v_cnt FROM finance.fn_holding_price_status(ARRAY[v_ok, v_miss]);
  SELECT price_status INTO v_txt FROM finance.depot_holdings_overview WHERE id = v_stale;
  RESET ROLE;
  IF v_cnt <> 2 OR v_txt IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'FAIL [5 finance_ro]: got cnt=% status=%', v_cnt, v_txt; END IF;
  RAISE NOTICE 'PASS finance_ro [Status-fn + View lesbar]';
END $$;
ROLLBACK;
