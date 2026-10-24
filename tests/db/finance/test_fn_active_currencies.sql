-- tests/db/finance/test_fn_active_currencies.sql
-- fn_active_currencies(): gibt DISTINCT non-EUR-Waehrungen zurueck, die echte Objekte
-- (finance_accounts oder finance_depot_holdings) nutzen. Keine finance_currencies-Abhaengigkeit.
BEGIN;

DO $$
DECLARE
  v_settle_id INT;
  v_depot_id  INT;
BEGIN

  -- Setup: USD als Fremdwaehrung (fuer FK-Compliance bei direktem INSERT)
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;

  -- TEST 1: EUR nie in der Menge (auch wenn EUR-Konto existiert)
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_eur_fxcheck__', 'cash', 'EUR', 'active');
  IF EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'EUR') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [EUR-Exclude]: EUR darf nie zurueckgegeben werden';
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [EUR-Exclude]';

  -- TEST 2: USD-Konto -> USD in Menge
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_usd_acct_fx__', 'cash', 'USD', 'active');
  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'USD') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [Account-USD]: USD soll nach Konto-Insert erscheinen';
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [Account-USD]';

  -- TEST 3: USD-Holding -> USD in Menge (Depot-Pfad)
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_settle_fxcheck__', 'cash', 'EUR', 'active')
  RETURNING id INTO v_settle_id;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__test_depot_fxcheck__', 'stocks_depot', 'EUR', 'active', v_settle_id)
  RETURNING id INTO v_depot_id;
  INSERT INTO finance.depot_holdings (account_id, name, symbol, currency)
  VALUES (v_depot_id, '__test_holding_usd_fx__', 'TSTU', 'USD');
  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'USD') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [Holding-USD]: USD via Holding soll erkannt werden';
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [Holding-USD]';

  -- TEST 4: DISTINCT (mehrere USD-Objekte -> nur einmal USD)
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_usd2_fxcheck__', 'cash', 'USD', 'active');
  IF (SELECT count(*) FROM finance.fn_active_currencies() WHERE code = 'USD') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [DISTINCT]: erwartet genau 1 mal USD, got %',
        (SELECT count(*) FROM finance.fn_active_currencies() WHERE code = 'USD');
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [DISTINCT: mehrere Objekte -> 1 Eintrag]';

  -- TEST 5 (WP-3a): quote_currency einer EUR-GEFUEHRTEN Position (US-Listing in GBP) -> GBP in der Menge.
  -- Red-first: vor der quote_currency-UNION taucht GBP NICHT auf -> FX-Cron holt den Kurs nie -> still 0.
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('GBP', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.depot_holdings (account_id, name, symbol, currency, quote_currency)
  VALUES (v_depot_id, '__test_holding_eur_gbpquote__', 'TSTG', 'EUR', 'GBP');
  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'GBP') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [quote_currency]: GBP (quote einer EUR-Position) fehlt -> FX-Cron holt den Kurs nie';
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [WP-3a quote_currency GBP erkannt]';

  -- TEST 6 (2026-10-23): Kurs-Waehrung aus market_prices einer GEHALTENEN Position ohne quote_currency (Feed liefert
  -- CHF) -> CHF in der Menge; eine nicht mehr gehaltene Position (shares=0) und ein aelterer Kurs in anderer Waehrung zaehlen nicht.
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2), ('JPY', 0) ON CONFLICT (code) DO NOTHING;
  PERFORM finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot_id, 'settlement_id', v_settle_id,
    'isin', 'CH0000000099', 'symbol', 'TSTC', 'shares', 2, 'price_per_share', 10, 'existing_position', true));
  INSERT INTO finance.market_prices (symbol, as_of, price, currency) VALUES ('TSTC', CURRENT_DATE, 11, 'CHF');
  INSERT INTO finance.market_prices (symbol, as_of, price, currency) VALUES ('TSTU', CURRENT_DATE, 5, 'JPY');   -- TSTU: 0 Stueck
  INSERT INTO finance.market_prices (symbol, as_of, price, currency) VALUES ('TSTC', CURRENT_DATE - 3, 1500, 'JPY');   -- aelterer Kurs: zaehlt nicht
  IF NOT EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'CHF') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [market_prices]: CHF (Kurs-Waehrung einer gehaltenen Position) fehlt';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_active_currencies() WHERE code = 'JPY') THEN
    RAISE EXCEPTION 'FAIL fn_active_currencies [market_prices]: JPY (Position ohne Bestand bzw. nur aelterer Kurs) darf nicht zaehlen';
  END IF;
  RAISE NOTICE 'PASS fn_active_currencies [Kurs-Waehrung gehaltener Positionen]';

END $$;

ROLLBACK;
