-- tests/db/finance/test_fn_feed_refresh_due.sql
-- fn_feed_refresh_due(): ein Abruf je Kalendertag (Haushalts-Zeitzone), nie bepreiste Symbole zaehlen nicht.
BEGIN;

DO $$
DECLARE
  v_settle int;
  v_depot  int;
  v_start  timestamptz := core.fn_today()::timestamp::timestamptz;  -- Beginn des heutigen Kalendertags (Sitzungs-Zeitzone)
  v_ok     boolean;
BEGIN
  DELETE FROM finance.fx_rates;
  DELETE FROM finance.market_prices;
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2), ('GBP', 2) ON CONFLICT (code) DO NOTHING;

  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies()) AND finance.fn_feed_refresh_due('fx') THEN
    RAISE EXCEPTION 'FAIL [fx leer]: ohne Fremdwaehrung nie faellig';
  END IF;

  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__frd_usd__', 'cash', 'USD', 'active'), ('__frd_gbp__', 'cash', 'GBP', 'active');
  IF NOT finance.fn_feed_refresh_due('fx') THEN
    RAISE EXCEPTION 'FAIL [fx ohne Kurs]: Waehrung ohne jeden Kurs ist faellig';
  END IF;

  -- Stand eine Minute vor Tagesbeginn -> faellig; genau Tagesbeginn -> nicht faellig
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source, updated_at)
  VALUES ('EUR', 'USD', 1.1, current_date - 1, 'test', v_start - interval '1 minute');
  IF NOT finance.fn_feed_refresh_due('fx') THEN
    RAISE EXCEPTION 'FAIL [fx gestern]: Stand vor Tagesbeginn ist faellig';
  END IF;
  UPDATE finance.fx_rates SET updated_at = v_start WHERE quote_currency = 'USD';
  IF finance.fn_feed_refresh_due('fx') THEN
    RAISE EXCEPTION 'FAIL [fx heute]: Stand ab Tagesbeginn ist nicht faellig (GBP ohne Kurs: ein frischer Kurs genuegt)';
  END IF;
  UPDATE finance.fx_rates SET updated_at = v_start - interval '4 days' WHERE quote_currency = 'USD';
  IF NOT finance.fn_feed_refresh_due('fx') THEN
    RAISE EXCEPTION 'FAIL [fx alt]: Stand von vor 4 Tagen ist faellig';
  END IF;
  RAISE NOTICE 'PASS fn_feed_refresh_due [fx]';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__frd_cash__', 'cash', 'EUR', 'active')
    RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__frd_depot__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_depot;
  IF NOT EXISTS (SELECT 1 FROM finance.depot_holdings WHERE shares > 0) AND finance.fn_feed_refresh_due('prices') THEN
    RAISE EXCEPTION 'FAIL [prices leer]: ohne Position nie faellig';
  END IF;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot, 'IE00FRDTEST1', 'FRDA', '__frd_a__', 1, 10, 'EUR'),
         (v_depot, 'IE00FRDTEST2', 'FRDB', '__frd_b__', 1, 10, 'EUR'),
         (v_depot, 'IE00FRDTEST3', 'FRDC', '__frd_c__', 0, 10, 'EUR');
  IF NOT finance.fn_feed_refresh_due('prices') THEN
    RAISE EXCEPTION 'FAIL [prices nie bepreist]: ohne jeden Kurs ist der Abruf faellig (Tagesplan muss holen)';
  END IF;
  INSERT INTO finance.market_prices (symbol, price, currency, as_of, source, updated_at)
  VALUES ('FRDA', 11, 'EUR', current_date - 1, 'test', v_start - interval '1 minute'),
         ('FRDC', 11, 'EUR', current_date - 1, 'test', v_start - interval '1 minute');
  IF NOT finance.fn_feed_refresh_due('prices') THEN
    RAISE EXCEPTION 'FAIL [prices gestern]: Stand vor Tagesbeginn ist faellig';
  END IF;
  -- FRDB nie bepreist, FRDA gestern: ein einzelnes nie bepreistes Symbol aendert nichts (nur Alter von FRDA zaehlt)
  -- FRDC ist verkauft (shares 0): ein frischer Kurs dort zaehlt nicht
  INSERT INTO finance.market_prices (symbol, price, currency, as_of, source, updated_at)
  VALUES ('FRDC', 12, 'EUR', current_date, 'test', v_start);
  IF NOT finance.fn_feed_refresh_due('prices') THEN
    RAISE EXCEPTION 'FAIL [prices verkauft]: frischer Kurs einer verkauften Position zaehlt nicht';
  END IF;
  INSERT INTO finance.market_prices (symbol, price, currency, as_of, source, updated_at)
  VALUES ('FRDB', 11, 'EUR', current_date, 'test', v_start);
  IF finance.fn_feed_refresh_due('prices') THEN
    RAISE EXCEPTION 'FAIL [prices heute]: Stand ab Tagesbeginn einer gehaltenen Position ist nicht faellig';
  END IF;
  RAISE NOTICE 'PASS fn_feed_refresh_due [prices]';

  BEGIN
    v_ok := finance.fn_feed_refresh_due('bogus');
    RAISE EXCEPTION 'FAIL [unbekannter Feed]: kein RAISE';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  RAISE NOTICE 'PASS fn_feed_refresh_due [unbekannter Feed]';
END $$;

ROLLBACK;
