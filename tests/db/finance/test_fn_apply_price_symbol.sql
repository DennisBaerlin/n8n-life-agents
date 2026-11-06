-- tests/db/finance/test_fn_apply_price_symbol.sql
-- Kurs-Luecken-Karte [Uebernehmen] (2026-10-27): finance.fn_apply_price_symbol = atomarer Write hinter dem Tipp.
-- Prueft:
--   (1) offene Luecke + unveraendertes Feed-Symbol -> provider_symbol + quote_currency gesetzt, Rueckgabe
--       {ok, holding_id, feed_symbol};
--   (2) quote_currency wird immer gesetzt: EUR ueberschreibt ein altes USD;
--   (3) Feed-Symbol seit der Karte geaendert -> {ok:false, code:'already_resolved'}, nichts geschrieben;
--   (4) Luecke inzwischen behoben (frischer Kurs) -> {ok:false, code:'already_resolved'};
--   (5) unbekannte/verkaufte Position -> {ok:false, code:'not_found'};
--   (6) finance_rw darf ausfuehren.
BEGIN;
DO $$
DECLARE
  v_cash int; v_depot int; v_h int; v_h2 int; v_sold int;
  r jsonb;
  v_ps text; v_qc text;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__aps_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__aps_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, provider_symbol, quote_currency)
  VALUES (v_depot,'IE00TESTAP01','APS','Fonds Ap', 2, 50, 'EUR', 'APSX', 'USD') RETURNING id INTO v_h;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TESTAP02','APT','Fonds Bt', 1, 10, 'EUR') RETURNING id INTO v_h2;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
  VALUES (v_depot,'IE00TESTAP03','APV','Fonds Weg', 0, 10, 'EUR') RETURNING id INTO v_sold;

  -- (3) zuerst: Karte zeigte ein anderes Feed-Symbol -> already_resolved, nichts geschrieben
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_h, 'expected_feed_symbol', 'APS',
         'provider_symbol', 'APS.DE', 'quote_currency', 'EUR'));
  SELECT provider_symbol, quote_currency INTO v_ps, v_qc FROM finance.depot_holdings WHERE id = v_h;
  IF (r->>'ok')::boolean OR r->>'code' <> 'already_resolved' OR v_ps <> 'APSX' OR v_qc <> 'USD' THEN
    RAISE EXCEPTION 'FAIL [3 symbol geaendert]: got % / %/%', r, v_ps, v_qc; END IF;
  RAISE NOTICE 'PASS fn_apply_price_symbol [Feed-Symbol seit der Karte geaendert -> already_resolved]';

  -- (1)+(2) offene Luecke, Feed-Symbol wie auf der Karte -> geschrieben, EUR ueberschreibt USD
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_h::text, 'expected_feed_symbol', 'APSX',
         'provider_symbol', 'aps.de', 'quote_currency', 'EUR'));
  SELECT provider_symbol, quote_currency INTO v_ps, v_qc FROM finance.depot_holdings WHERE id = v_h;
  IF NOT (r->>'ok')::boolean OR (r->>'holding_id')::int <> v_h OR r->>'feed_symbol' <> 'APS.DE'
     OR v_ps <> 'APS.DE' OR v_qc <> 'EUR' THEN
    RAISE EXCEPTION 'FAIL [1/2 write]: got % / %/%', r, v_ps, v_qc; END IF;
  RAISE NOTICE 'PASS fn_apply_price_symbol [provider_symbol gross, quote_currency EUR ueberschreibt USD]';

  -- (4) Luecke inzwischen behoben
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('APT', 11, 'EUR', current_date);
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_h2, 'expected_feed_symbol', 'APT',
         'provider_symbol', 'APT.DE', 'quote_currency', 'EUR'));
  SELECT provider_symbol INTO v_ps FROM finance.depot_holdings WHERE id = v_h2;
  IF (r->>'ok')::boolean OR r->>'code' <> 'already_resolved' OR v_ps IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [4 behoben]: got % / %', r, v_ps; END IF;
  RAISE NOTICE 'PASS fn_apply_price_symbol [Kurs inzwischen da -> already_resolved]';

  -- (5) verkaufte / unbekannte Position
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_sold, 'expected_feed_symbol', 'APV',
         'provider_symbol', 'APV.DE', 'quote_currency', 'EUR'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'not_found' THEN
    RAISE EXCEPTION 'FAIL [5 verkauft]: got %', r; END IF;
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', -1, 'expected_feed_symbol', 'X',
         'provider_symbol', 'X.DE', 'quote_currency', 'EUR'));
  IF (r->>'ok')::boolean OR r->>'code' <> 'not_found' THEN
    RAISE EXCEPTION 'FAIL [5 unbekannt]: got %', r; END IF;
  RAISE NOTICE 'PASS fn_apply_price_symbol [verkauft/unbekannt -> not_found]';

  -- (6) finance_rw
  DELETE FROM finance.market_prices WHERE symbol = 'APT';
  SET LOCAL ROLE finance_rw;
  r := finance.fn_apply_price_symbol(jsonb_build_object('holding_id', v_h2, 'expected_feed_symbol', 'APT',
         'provider_symbol', 'APT.DE', 'quote_currency', 'EUR'));
  RESET ROLE;
  IF NOT (r->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [6 finance_rw]: got %', r; END IF;
  RAISE NOTICE 'PASS finance_rw [fn_apply_price_symbol ausfuehrbar]';
END $$;
ROLLBACK;
