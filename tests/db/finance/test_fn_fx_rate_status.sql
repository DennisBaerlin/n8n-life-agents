-- tests/db/finance/test_fn_fx_rate_status.sql
-- fn_fx_rate_status(): je aktive Fremdwaehrung ok | stale | missing, auch fuer eine Waehrung, die erst der Kursabruf lernt.
BEGIN;

DO $$
DECLARE
  v_settle int;
  v_depot  int;
  v_r      jsonb;
  v_stale  int := NULLIF(core.fn_config_get('finance', 'finance', 'fx_stale_days'), '')::int;
BEGIN
  DELETE FROM finance.fx_rates;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies()) AND EXISTS (SELECT 1 FROM finance.fn_fx_rate_status()) THEN
    RAISE EXCEPTION 'FAIL [leer]: ohne Fremdwaehrung darf nichts gemeldet werden';
  END IF;
  INSERT INTO finance.currencies (code, minor_unit)
  VALUES ('USD', 2), ('GBP', 2), ('CHF', 2), ('SEK', 2) ON CONFLICT (code) DO NOTHING;

  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__fxs_cash__', 'cash', 'EUR', 'active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__fxs_depot__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_depot;

  -- Fall aus dem Import: Position in EUR, quote_currency EUR, erst der Kursabruf liefert GBP.
  PERFORM finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin', 'IE00FXSTAT01', 'symbol', 'FXSG', 'shares', 2, 'price_per_share', 10,
    'quote_currency', 'EUR', 'existing_position', true));
  IF EXISTS (SELECT 1 FROM finance.fn_fx_rate_status() WHERE code = 'GBP') THEN
    RAISE EXCEPTION 'FAIL [vor Kursabruf]: GBP ist noch nicht bekannt';
  END IF;
  v_r := finance.fn_upsert_market_prices(jsonb_build_object(
    'prices', jsonb_build_object('FXSG', 11), 'currencies', jsonb_build_object('FXSG', 'GBP'), 'source', 'test'));
  IF (SELECT status FROM finance.fn_fx_rate_status() WHERE code = 'GBP') IS DISTINCT FROM 'missing' THEN
    RAISE EXCEPTION 'FAIL [gelernte Waehrung]: GBP soll nach dem Kursabruf missing sein, %',
      (SELECT jsonb_agg(s) FROM finance.fn_fx_rate_status() s);
  END IF;
  IF (SELECT last_as_of FROM finance.fn_fx_rate_status() WHERE code = 'GBP') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [missing]: last_as_of muss NULL sein';
  END IF;
  RAISE NOTICE 'PASS fn_fx_rate_status [gelernte Kurswaehrung ohne Kurs = missing]';

  -- Grenze: genau fx_stale_days alt ist noch ok, einen Tag aelter stale (wie fn_staleness_alert: alter > schwelle).
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__fxs_usd__', 'cash', 'USD', 'active'), ('__fxs_chf__', 'cash', 'CHF', 'active'), ('__fxs_sek__', 'cash', 'SEK', 'active');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR', 'USD', 1.1, current_date - v_stale, 'test'),
         ('EUR', 'CHF', 0.9, current_date - v_stale - 1, 'test'),
         ('EUR', 'SEK', 11, current_date - 30, 'test'),
         ('EUR', 'SEK', 12, current_date, 'test');
  IF (SELECT status FROM finance.fn_fx_rate_status() WHERE code = 'USD') IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'FAIL [Grenze ok]: USD genau an der Grenze soll ok sein';
  END IF;
  IF (SELECT status FROM finance.fn_fx_rate_status() WHERE code = 'CHF') IS DISTINCT FROM 'stale' THEN
    RAISE EXCEPTION 'FAIL [Grenze stale]: CHF einen Tag ueber der Grenze soll stale sein';
  END IF;
  IF (SELECT status FROM finance.fn_fx_rate_status() WHERE code = 'SEK') IS DISTINCT FROM 'ok' THEN
    RAISE EXCEPTION 'FAIL [juengster Kurs]: SEK zaehlt mit dem juengsten Kurs';
  END IF;
  IF (SELECT last_as_of FROM finance.fn_fx_rate_status() WHERE code = 'CHF') IS DISTINCT FROM current_date - v_stale - 1 THEN
    RAISE EXCEPTION 'FAIL [last_as_of]: falsches Datum fuer CHF';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_fx_rate_status() WHERE code = 'EUR') THEN
    RAISE EXCEPTION 'FAIL [EUR]: EUR braucht keinen Kurs';
  END IF;
  RAISE NOTICE 'PASS fn_fx_rate_status [Grenze, juengster Kurs, EUR]';
END $$;

ROLLBACK;
