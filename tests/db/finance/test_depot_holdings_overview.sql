-- tests/db/finance/test_depot_holdings_overview.sql
-- Phase M: Live-Marktwert in finance.depot_holdings_overview + die quote_currency-Konvertierung in den BEIDEN
-- markt-wertenden Views. Prueft:
--   (1) market_value/_eur/price_as_of/unrealized_gain_eur bei vorhandenem Kurs (EUR-Holding);
--   (2) NULL-Semantik OHNE Kurs (KEIN Buchwert-Fallback in der Anzeige-View), book_value bleibt gefuellt;
--   (3) quote_currency=USD: der Kurs wird in SEINER Waehrung (lp.price_currency) nach EUR konvertiert, nicht
--       in der Holding-Aufnahme-Waehrung -- in depot_holdings_overview.market_value_eur UND in
--       networth_by_asset_class.value_eur (sonst stille Fehl-Umrechnung);
--   (4) finance_ro liest depot_holdings_overview MIT market_prices-Zeile (Rollen-Lesepfad, m8a).
BEGIN;
DO $$
DECLARE
  v_cash INT; v_depot INT; v_h_eur INT; v_h_nop INT; v_h_usd INT;
  v_mv NUMERIC; v_mv_eur NUMERIC; v_pa DATE; v_gain NUMERIC; v_bv NUMERIC; v_nw NUMERIC;
BEGIN
  -- USD registrieren + fixer EUR->USD-Kurs 1.10 (1000 USD / 1.10 = 909.09 EUR)
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR','USD', 1.10, CURRENT_DATE, 'test')
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__dho_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__dho_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;

  -- (1) EUR-Holding MIT Kurs: shares 5, avg 100 (book 500), market_price 110 EUR -> market_value 550, gain 50
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_depot, 'IE00BK5BQT80','VWCE','Vanguard FTSE All-World', 5, 100, 'EUR', 'sp500') RETURNING id INTO v_h_eur;
  INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of)
  VALUES ('VWCE','IE00BK5BQT80', 110, 'EUR', current_date);

  SELECT market_value, market_value_eur, price_as_of, unrealized_gain_eur, book_value
    INTO v_mv, v_mv_eur, v_pa, v_gain, v_bv FROM finance.depot_holdings_overview WHERE id = v_h_eur;
  IF v_mv IS DISTINCT FROM 550 OR v_mv_eur IS DISTINCT FROM 550 THEN
    RAISE EXCEPTION 'FAIL [1 eur mv]: erwartet 550/550, got %/%', v_mv, v_mv_eur; END IF;
  IF v_pa IS DISTINCT FROM current_date THEN
    RAISE EXCEPTION 'FAIL [1 eur price_as_of]: erwartet heute, got %', v_pa; END IF;
  IF v_bv IS DISTINCT FROM 500 OR v_gain IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL [1 eur gain]: erwartet book 500 / gain 50, got %/%', v_bv, v_gain; END IF;
  RAISE NOTICE 'PASS depot_holdings_overview [EUR Holding: market_value 550, gain 50, price_as_of gesetzt]';

  -- (2) Holding OHNE Kurs: market_value/_eur/gain/price_as_of NULL (KEIN Buchwert-Fallback), book_value 320
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot, 'IE00B4L5Y983','IWDA','iShares Core', 4, 80, 'EUR') RETURNING id INTO v_h_nop;
  SELECT market_value, market_value_eur, price_as_of, unrealized_gain_eur, book_value
    INTO v_mv, v_mv_eur, v_pa, v_gain, v_bv FROM finance.depot_holdings_overview WHERE id = v_h_nop;
  IF v_mv IS NOT NULL OR v_mv_eur IS NOT NULL OR v_pa IS NOT NULL OR v_gain IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2 no price]: alle Marktwert-Spalten muessen NULL sein, got mv=% mv_eur=% pa=% gain=%', v_mv, v_mv_eur, v_pa, v_gain; END IF;
  IF v_bv IS DISTINCT FROM 320 THEN
    RAISE EXCEPTION 'FAIL [2 no price book]: book_value muss 320 sein (immer gefuellt), got %', v_bv; END IF;
  RAISE NOTICE 'PASS depot_holdings_overview [ohne Kurs: Marktwert-Spalten NULL, book_value 320]';

  -- (3) quote_currency=USD: Kurs 100 USD, shares 10 -> market_value 1000 (nativ USD); market_value_eur =
  -- 1000 USD / 1.10 = 909.09 (in USD konvertiert, NICHT als EUR). Beweist lp.price_currency statt h.currency.
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, quote_currency, asset_class)
  VALUES (v_depot, 'US9229087690','VUSA','Vanguard S&P 500', 10, 90, 'EUR', 'USD', 'usintl') RETURNING id INTO v_h_usd;
  INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of)
  VALUES ('VUSA','US9229087690', 100, 'USD', current_date);

  SELECT market_value, market_value_eur INTO v_mv, v_mv_eur FROM finance.depot_holdings_overview WHERE id = v_h_usd;
  IF v_mv IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL [3 usd mv native]: erwartet 1000 (USD nativ), got %', v_mv; END IF;
  IF round(v_mv_eur, 2) IS DISTINCT FROM 909.09 THEN
    RAISE EXCEPTION 'FAIL [3 usd mv_eur]: erwartet 909.09 (1000 USD / 1.10) -- wird h.currency statt lp.price_currency genutzt? got %', round(v_mv_eur, 2); END IF;
  RAISE NOTICE 'PASS depot_holdings_overview [quote_currency USD: market_value 1000 nativ, _eur 909.09 (USD-konvertiert)]';

  -- networth_by_asset_class: dieselbe USD-Konvertierung des Live-Kurses (value_eur = 909.09, nicht 1000)
  SELECT value_eur INTO v_nw FROM finance.networth_by_asset_class WHERE asset_class = 'usintl';
  IF round(v_nw, 2) IS DISTINCT FROM 909.09 THEN
    RAISE EXCEPTION 'FAIL [3 networth usd]: erwartet 909.09 (Live-Kurs in lp.currency konvertiert) -- Fehl-Umrechnung mit h.currency? got %', round(v_nw, 2); END IF;
  RAISE NOTICE 'PASS networth_by_asset_class [quote_currency USD: 909.09, Live-Kurs in lp.currency konvertiert]';

  -- (4) m8a: finance_ro liest depot_holdings_overview MIT market_prices-Zeile (Rollen-Lesepfad) ohne Fehler.
  SET LOCAL ROLE finance_ro;
  SELECT market_value INTO v_mv FROM finance.depot_holdings_overview WHERE id = v_h_eur;
  RESET ROLE;
  IF v_mv IS DISTINCT FROM 550 THEN
    RAISE EXCEPTION 'FAIL [4 finance_ro]: finance_ro las market_value nicht korrekt (550), got %', v_mv; END IF;
  RAISE NOTICE 'PASS depot_holdings_overview [finance_ro liest Marktwert ueber market_prices (m8a)]';
END $$;
ROLLBACK;
