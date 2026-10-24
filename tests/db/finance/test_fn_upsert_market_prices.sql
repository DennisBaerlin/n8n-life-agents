-- tests/db/finance/test_fn_upsert_market_prices.sql
-- fn_upsert_market_prices (WS2b Core-Advisor-Engine): Markt-Preis-Upsert NUR fuer Symbole, die als
-- gehaltene Depot-Position (depot_holdings WHERE shares>0) existieren (Objekt-getrieben, kein Spam fuer
-- nicht gehaltene Ticker — Muster fn_upsert_fx_rates). Guards: Symbol gehalten, numerisch+>0,
-- Tages-Idempotenz (PK symbol,as_of), leeres prices-Objekt -> ok:false. Preis-Waehrung = Holding-Waehrung.
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_as_of    DATE := DATE '2026-06-20';
  v_price    NUMERIC;
  v_ccy      CHAR(3);
  v_acct     INT;
  v_depot    INT;
BEGIN

  -- Setup: ein Verrechnungs-Cash-Konto + ein stocks_depot + zwei Holdings (eine gehalten, eine sold-off).
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_settle_mp__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__test_depot_mp__', 'stocks_depot', 'EUR', 'active', v_acct) RETURNING id INTO v_depot;

  -- gehaltene Position (shares>0, EUR) — Trigger pflegt shares normalerweise; im Test direkt setzen.
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency)
  VALUES (v_depot, 'IE00BK5BQT80', 'VWCE', 'Vanguard FTSE All-World', 5, 'EUR');
  -- sold-off Position (shares=0) -> NICHT im Symbol-Set
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency)
  VALUES (v_depot, 'IE00BSOLD000', 'SOLD', 'Sold Off', 0, 'EUR');

  -- TEST 1: Upsert nur fuer gehaltenes Symbol; SOLD (shares=0) + UNHELD (kein Holding) werden NICHT geschrieben.
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text,
    'prices', jsonb_build_object('VWCE', 110.50, 'SOLD', 5, 'UNHELD', 9, 'BAD', 'n/a', 'ZER', 0)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [1]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.market_prices WHERE symbol = 'VWCE' AND as_of = v_as_of) THEN
    RAISE EXCEPTION 'FAIL [1]: VWCE-Preis wurde nicht geschrieben';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.market_prices WHERE symbol IN ('SOLD','UNHELD','BAD','ZER') AND as_of = v_as_of) THEN
    RAISE EXCEPTION 'FAIL [1]: nicht-gehaltenes/ungueltiges Symbol wurde geschrieben (result=%)', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [nur gehaltenes Symbol; sold-off/unheld/0/non-numeric skip]';

  -- Assert: Preis + Waehrung (aus dem Holding abgeleitet) korrekt
  SELECT price, currency INTO v_price, v_ccy FROM finance.market_prices WHERE symbol = 'VWCE' AND as_of = v_as_of;
  IF v_price IS DISTINCT FROM 110.50 THEN
    RAISE EXCEPTION 'FAIL [2]: erwartet 110.50, got %', v_price;
  END IF;
  IF v_ccy IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [2]: erwartet Waehrung EUR (aus Holding), got %', v_ccy;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [Preis + abgeleitete Waehrung korrekt]';

  -- TEST 3: Idempotenz — gleicher as_of, neuer Preis -> UPDATE, kein zweites INSERT
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text,
    'prices', jsonb_build_object('VWCE', 111.00)
  )) INTO v_result;
  SELECT price INTO v_price FROM finance.market_prices WHERE symbol = 'VWCE' AND as_of = v_as_of;
  IF v_price IS DISTINCT FROM 111.00 THEN
    RAISE EXCEPTION 'FAIL [3]: erwartet 111.00 nach Update, got %', v_price;
  END IF;
  IF (SELECT count(*) FROM finance.market_prices WHERE symbol = 'VWCE' AND as_of = v_as_of) <> 1 THEN
    RAISE EXCEPTION 'FAIL [3]: Tages-Dublette fuer (VWCE,%)', v_as_of;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [Tages-Idempotenz: UPDATE statt INSERT]';

  -- TEST 4: source-Default ('yahoo' = aktueller Provider) greift, wenn nicht uebergeben
  IF (SELECT source FROM finance.market_prices WHERE symbol = 'VWCE' AND as_of = v_as_of) <> 'yahoo' THEN
    RAISE EXCEPTION 'FAIL [4]: source-Default yahoo nicht gesetzt';
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [source-Default yahoo]';

  -- TEST 4b (Cold-Eyes A4): wissenschaftliche Notation (sub-microcent-Krypto, JSON '1e-7') wird akzeptiert
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, currency)
  VALUES (v_depot, 'TINY', 'Tiny Token', 1000000, 'EUR');
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text,
    'prices', jsonb_build_object('TINY', '1e-7')   -- als String -> ->> liefert '1e-7' (wie JS JSON.stringify)
  )) INTO v_result;
  IF NOT EXISTS (SELECT 1 FROM finance.market_prices WHERE symbol = 'TINY' AND as_of = v_as_of AND price > 0) THEN
    RAISE EXCEPTION 'FAIL [4b]: wissenschaftliche Notation 1e-7 wurde verworfen, result=%', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [wissenschaftliche Notation 1e-7 akzeptiert]';

  -- TEST 5: fehlendes prices-Objekt -> ok:false, kein RAISE
  SELECT finance.fn_upsert_market_prices('{"as_of":"2026-06-20"}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [5]: erwartet ok=false ohne prices-Objekt, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [kein prices-Objekt -> ok:false]';

  -- TEST 6 (Phase M): quote_currency ueberschreibt die Holding-Waehrung als Kurs-Waehrung.
  -- Holding QC in EUR gefuehrt, aber quote_currency=USD (US-Listing) -> market_prices.currency = USD.
  -- Setup: USD registrieren (der fn-Pfad macht das via fn_ensure_currency; hier inserten wir direkt, daher
  -- den FK depot_holdings.quote_currency->currencies vorab bedienen). market_prices.currency erbt den FK ebenso.
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency, quote_currency)
  VALUES (v_depot, 'US0000000QC1', 'QCS', 'Quote Ccy Stock', 3, 'EUR', 'USD');
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text, 'prices', jsonb_build_object('QCS', 42.00)
  )) INTO v_result;
  SELECT currency INTO v_ccy FROM finance.market_prices WHERE symbol = 'QCS' AND as_of = v_as_of;
  IF v_ccy IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [6]: erwartet quote_currency USD in market_prices, got % (result=%)', v_ccy, v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [quote_currency override -> market_prices.currency=USD]';

  -- TEST 7 (Phase M, M4): gleiches Symbol in ZWEI Depots, eines mit quote_currency=USD, eines ohne (currency=EUR).
  -- Korrekte Aggregation = min(COALESCE(quote_currency, currency)) PRO ZEILE -> min(USD-Zeile, EUR-Zeile) = 'EUR'.
  -- Der fruehere Bug COALESCE(min(quote_currency), min(currency)) = COALESCE(USD, EUR) = USD wuerde die Waehrungen
  -- ueber Zeilen MISCHEN. Wir asserten 'EUR' -> beweist die per-Zeile-Aufloesung.
  DECLARE v_cash2 INT; v_depot2 INT; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__test_settle_mp2__', 'cash', 'EUR', 'active') RETURNING id INTO v_cash2;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__test_depot_mp2__', 'stocks_depot', 'EUR', 'active', v_cash2) RETURNING id INTO v_depot2;
    -- Zeile A (Depot 1): MIX, quote_currency=USD
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency, quote_currency)
    VALUES (v_depot, 'IE0000MIXED1', 'MIX', 'Mixed A', 2, 'EUR', 'USD');
    -- Zeile B (Depot 2): MIX, quote_currency NULL -> COALESCE faellt auf currency=EUR
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency)
    VALUES (v_depot2, 'IE0000MIXED1', 'MIX', 'Mixed B', 4, 'EUR');
    SELECT finance.fn_upsert_market_prices(jsonb_build_object(
      'as_of', v_as_of::text, 'prices', jsonb_build_object('MIX', 9.00)
    )) INTO v_result;
    SELECT currency INTO v_ccy FROM finance.market_prices WHERE symbol = 'MIX' AND as_of = v_as_of;
    IF v_ccy IS DISTINCT FROM 'EUR' THEN
      RAISE EXCEPTION 'FAIL [7]: erwartet min(per-Zeile-COALESCE)=EUR (keine Mischung), got % (result=%)', v_ccy, v_result;
    END IF;
    RAISE NOTICE 'PASS fn_upsert_market_prices [min(COALESCE) pro Zeile, keine Waehrungs-Mischung]';
  END;

  -- TEST 8 (Yahoo-Robustheit): die GEFETCHTE Waehrung (Payload currencies{}) gewinnt ueber quote_currency/holding
  -- UND wird von fn_upsert registriert (fn_ensure_currency), auch wenn sie noch nicht in finance.currencies steht.
  -- Holding FCW: currency=EUR, quote_currency=USD; Fetch currencies={FCW:'CHF'} (CHF nicht vorab registriert).
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency, quote_currency)
  VALUES (v_depot, 'CH0000000FCW', 'FCW', 'Fetched Ccy Wins', 5, 'EUR', 'USD');
  -- Setup robust: sicherstellen, dass CHF NICHT vorab registriert ist (Beweis-Voraussetzung, dass fn_upsert sie anlegt).
  -- BEGIN/ROLLBACK -> kein Residual; DELETE statt IF-EXISTS-RAISE, das bei breiteren Currency-Seeds spurious feuern wuerde.
  DELETE FROM finance.currencies WHERE code = 'CHF';
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text, 'prices', jsonb_build_object('FCW', 88.00),
    'currencies', jsonb_build_object('FCW', 'CHF')
  )) INTO v_result;
  SELECT currency INTO v_ccy FROM finance.market_prices WHERE symbol = 'FCW' AND as_of = v_as_of;
  IF v_ccy IS DISTINCT FROM 'CHF' THEN
    RAISE EXCEPTION 'FAIL [8]: gefetchte Waehrung CHF muss gewinnen (ueber quote_currency USD/holding EUR), got % (result=%)', v_ccy, v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.currencies WHERE code = 'CHF') THEN
    RAISE EXCEPTION 'FAIL [8]: fn_upsert hat die gefetchte Waehrung CHF nicht registriert (FK-Schutz)';
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [gefetchte Yahoo-Waehrung gewinnt + wird registriert]';

  -- TEST 9 (Yahoo-Robustheit): eine INVALIDE gefetchte Waehrung (kein ^[A-Z]{3}$) faellt defensiv auf h.currency
  -- zurueck statt FK-RAISE im Cron. Holding BADC: currency=EUR; Fetch currencies={BADC:'gbp'} (lowercase = invalid).
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, currency)
  VALUES (v_depot, 'XX0000000BAD', 'BADC', 'Bad Fetched Ccy', 2, 'EUR');
  SELECT finance.fn_upsert_market_prices(jsonb_build_object(
    'as_of', v_as_of::text, 'prices', jsonb_build_object('BADC', 10.00),
    'currencies', jsonb_build_object('BADC', 'gbp')
  )) INTO v_result;
  SELECT currency INTO v_ccy FROM finance.market_prices WHERE symbol = 'BADC' AND as_of = v_as_of;
  IF v_ccy IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [9]: invalide gefetchte Waehrung muss auf h.currency=EUR zurueckfallen (kein FK-RAISE), got % (result=%)', v_ccy, v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_market_prices [invalide gefetchte Waehrung -> Fallback h.currency, kein FK-RAISE]';

END $$;

ROLLBACK;
