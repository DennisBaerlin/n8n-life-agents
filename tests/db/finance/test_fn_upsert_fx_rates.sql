-- tests/db/finance/test_fn_upsert_fx_rates.sql
-- fn_upsert_fx_rates: Kurs-Upsert fuer jede gelieferte Waehrung (Vorhaltung unabhaengig vom Bedarf),
-- neue Codes landen mit ISO-minor_unit in finance.currencies; Guards (Format, numerisch+>0, EUR-Key) zaehlen in
-- skipped; Tages-Idempotenz; as_of aus dem Payload (Quell-Datum); kein rates-Objekt -> ok:false.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_as_of   DATE := DATE '2026-06-07';
  v_rate    NUMERIC;
BEGIN
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('USD', 'JPY', 'KWD', 'CLF', 'GGP');

  -- [1] Waehrung ohne Konto/Position wird geschrieben; [3] Muell-Keys werden uebersprungen und gezaehlt
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object(
    'as_of', v_as_of::text,
    'rates', jsonb_build_object('EUR', 1, 'USD', 1.08, 'JPY', 1500.5, 'KWD', 0.331, 'CLF', 0.0281, 'GGP', 0.85,
                                'BAD', 'n/a', 'ZER', 0, 'NEG', -2, 'usd', 1.1, 'ABCD', 3)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'upserted')::int IS DISTINCT FROM 5
     OR (v_result->>'skipped')::int IS DISTINCT FROM 6 THEN
    RAISE EXCEPTION 'FAIL upsert [1/3]: erwartet ok, upserted 5, skipped 6 (EUR, n/a, 0, negativ, klein, 4 Buchstaben), got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE currency = 'JPY') OR NOT EXISTS (
       SELECT 1 FROM finance.fx_rates WHERE base_currency = 'EUR' AND quote_currency = 'JPY' AND as_of = v_as_of AND rate = 1500.5) THEN
    RAISE EXCEPTION 'FAIL upsert [1]: JPY ohne Konto muss geschrieben sein';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency IN ('BAD', 'ZER', 'NEG', 'EUR') OR quote_currency ~ '[a-z]') THEN
    RAISE EXCEPTION 'FAIL upsert [3]: ungueltige Keys wurden geschrieben';
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [1 ohne Objekt geschrieben, 3 Muell-Keys skipped]';

  -- [2] neue Codes in finance.currencies mit richtigem minor_unit
  IF (SELECT jsonb_object_agg(code, minor_unit) FROM finance.currencies WHERE code IN ('USD', 'JPY', 'KWD', 'CLF', 'GGP'))
     IS DISTINCT FROM '{"USD": 2, "JPY": 0, "KWD": 3, "CLF": 4, "GGP": 2}'::jsonb THEN
    RAISE EXCEPTION 'FAIL upsert [2 minor_unit]: %',
      (SELECT jsonb_object_agg(code, minor_unit) FROM finance.currencies WHERE code IN ('USD', 'JPY', 'KWD', 'CLF', 'GGP'));
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [2 Waehrungen registriert, ISO-minor_unit]';

  -- [4] Idempotenz — gleicher as_of, neuer Kurs -> UPDATE, kein zweites INSERT
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object('as_of', v_as_of::text, 'rates', jsonb_build_object('USD', 1.09)))
    INTO v_result;
  SELECT rate INTO v_rate FROM finance.fx_rates WHERE base_currency = 'EUR' AND quote_currency = 'USD' AND as_of = v_as_of;
  IF v_rate IS DISTINCT FROM 1.09
     OR (SELECT count(*) FROM finance.fx_rates WHERE quote_currency = 'USD' AND as_of = v_as_of) IS DISTINCT FROM 1::bigint
     OR (v_result->>'upserted')::int IS DISTINCT FROM 1 OR (v_result->>'skipped')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL upsert [4 Idempotenz]: rate %, result %', v_rate, v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [4 Tages-Idempotenz]';

  -- [5] fehlendes rates-Objekt -> ok:false, kein RAISE
  SELECT finance.fn_upsert_fx_rates('{"as_of":"2026-06-07"}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL upsert [5 kein rates-Objekt]: erwartet ok=false, got %', v_result;
  END IF;

  -- [5b] as_of aus dem Payload (Quell-Datum) wird verwendet; ohne as_of -> heute
  SELECT finance.fn_upsert_fx_rates('{"as_of":"2026-05-30","rates":{"USD":1.07}}'::jsonb) INTO v_result;
  IF v_result->>'as_of' IS DISTINCT FROM '2026-05-30'
     OR NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'USD' AND as_of = DATE '2026-05-30') THEN
    RAISE EXCEPTION 'FAIL upsert [5b Quell-Datum]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [5 ok:false ohne rates, 5b Quell-Datum]';

  -- [h1-h4] Zeilen-Modus (EZB-Nachlauf): rows [{date, base, quote, rate}], source ecb; vorhandener Tageskurs gewinnt
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('USD', 'ISK');
  DELETE FROM finance.currencies WHERE code = 'ISK';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'USD', 1.5, DATE '2026-05-04', 'open.er-api.com');
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object('source', 'ecb', 'rows', jsonb_build_array(
    jsonb_build_object('date', '2026-05-04', 'base', 'EUR', 'quote', 'USD', 'rate', 1.2),
    jsonb_build_object('date', '2026-05-05', 'base', 'EUR', 'quote', 'USD', 'rate', 1.21),
    jsonb_build_object('date', '2026-05-05', 'base', 'EUR', 'quote', 'ISK', 'rate', 150),
    jsonb_build_object('date', '2026-05-05', 'base', 'USD', 'quote', 'JPY', 'rate', 1400),
    jsonb_build_object('date', '05.05.2026', 'base', 'EUR', 'quote', 'USD', 'rate', 1.3),
    jsonb_build_object('date', '2026-02-30', 'base', 'EUR', 'quote', 'USD', 'rate', 1.3),
    jsonb_build_object('date', '2026-05-06', 'base', 'EUR', 'quote', 'USD', 'rate', 0),
    jsonb_build_object('date', '2026-05-06', 'base', 'EUR', 'quote', 'EUR', 'rate', 1)
  ))) INTO v_result;
  -- [h1] 2 neue Zeilen (USD 05-05, ISK 05-05), 05-04 existiert schon (DO NOTHING zaehlt nicht), 5 Muell-Zeilen
  -- (Basis USD, Datum im falschen Format, unmoegliches Datum, Kurs 0, EUR als Ziel)
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'upserted')::int IS DISTINCT FROM 2
     OR (v_result->>'skipped')::int IS DISTINCT FROM 6 OR v_result->>'as_of' IS DISTINCT FROM '2026-05-05' THEN
    RAISE EXCEPTION 'FAIL upsert [h1 rows]: erwartet upserted 2, skipped 6 (1 vorhanden + 5 ungueltig, auch 30. Februar), as_of 2026-05-05, got %', v_result;
  END IF;
  -- [h2] vorhandener Tageskurs bleibt (Rate und Quelle)
  IF NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'USD' AND as_of = DATE '2026-05-04' AND rate = 1.5 AND source = 'open.er-api.com') THEN
    RAISE EXCEPTION 'FAIL upsert [h2]: Nachlauf darf einen vorhandenen Tageskurs nicht ueberschreiben';
  END IF;
  -- [h3] neue Waehrung registriert (ISK 0 Stellen), Quelle ecb gesetzt
  IF (SELECT minor_unit FROM finance.currencies WHERE code = 'ISK') IS DISTINCT FROM 0::smallint
     OR NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'ISK' AND as_of = DATE '2026-05-05' AND source = 'ecb') THEN
    RAISE EXCEPTION 'FAIL upsert [h3]: ISK registriert + source ecb';
  END IF;
  -- [h4] der Tages-Feed ueberschreibt spaeter eine EZB-Zeile desselben Tages (Feed gewinnt in beide Richtungen)
  PERFORM finance.fn_upsert_fx_rates('{"as_of":"2026-05-05","rates":{"USD":1.25}}'::jsonb);
  IF NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'USD' AND as_of = DATE '2026-05-05' AND rate = 1.25 AND source = 'open.er-api.com') THEN
    RAISE EXCEPTION 'FAIL upsert [h4]: Tages-Feed gewinnt gegen EZB-Zeile';
  END IF;
  -- Zeilen-Modus nur mit fremder Quelle: ohne source gilt ecb, nie die Feed-Kennung
  SELECT finance.fn_upsert_fx_rates('{"rows":[{"date":"2026-04-30","base":"EUR","quote":"USD","rate":1.19}]}'::jsonb) INTO v_result;
  IF NOT EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'USD' AND as_of = DATE '2026-04-30' AND source = 'ecb') THEN
    RAISE EXCEPTION 'FAIL upsert [rows ohne source -> ecb]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [h1 Zeilen-Modus, h2 Tageskurs bleibt, h3 neue Waehrung, h4 Feed gewinnt]';
END $$;

-- [m1-m5] Edelmetalle (XAU/XAG, currencies.kind = 'metal'): die Quelle liefert "1 Feinunze = r EUR"; gespeichert wird
-- EUR -> Metall mit rate = 1/r (die DB invertiert), Quelle fn_fx_metal_source(); gleiche Quelle zieht den Tageswert nach.
DO $$
DECLARE
  v_result JSONB;
  v_rate   NUMERIC;
  v_utc    DATE := (now() AT TIME ZONE 'UTC')::date;
BEGIN
  DELETE FROM finance.fx_rates WHERE quote_currency IN ('XAU', 'XAG', 'USD');
  IF (SELECT jsonb_object_agg(code, kind) FROM finance.currencies WHERE code IN ('XAU', 'XAG'))
     IS DISTINCT FROM '{"XAU": "metal", "XAG": "metal"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL upsert [m0]: XAU/XAG muessen als metal geseedet sein';
  END IF;

  -- [m1] Metall-Zeile wird invertiert gespeichert, fn_fx_rate liefert den Preis je Feinunze zurueck
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('date', '2026-05-05', 'base', 'XAU', 'quote', 'EUR', 'rate', 3236.31),
    jsonb_build_object('date', '2026-05-05', 'base', 'XAG', 'quote', 'EUR', 'rate', 37.393),
    jsonb_build_object('date', '2026-05-05', 'base', 'XAU', 'quote', 'USD', 'rate', 3544.94),
    jsonb_build_object('date', '2026-05-05', 'base', 'XAU', 'quote', 'EUR', 'rate', 0)
  ))) INTO v_result;
  IF (v_result->>'upserted')::int IS DISTINCT FROM 2 OR (v_result->>'skipped')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL upsert [m1 Zaehler]: erwartet upserted 2, skipped 2 (Metall gegen USD, Kurs 0), got %', v_result;
  END IF;
  SELECT rate INTO v_rate FROM finance.fx_rates
  WHERE base_currency = 'EUR' AND quote_currency = 'XAU' AND as_of = DATE '2026-05-05' AND source = finance.fn_fx_metal_source();
  IF v_rate IS DISTINCT FROM round(1 / 3236.31, 10) THEN
    RAISE EXCEPTION 'FAIL upsert [m1 Inversion]: erwartet %, got %', round(1 / 3236.31, 10), v_rate;
  END IF;
  IF abs((SELECT f.rate FROM finance.fn_fx_rate('XAU', 'EUR', DATE '2026-05-05') f) - 3236.31) > 0.01
     OR abs((SELECT f.rate FROM finance.fn_fx_rate('XAG', 'EUR', DATE '2026-05-05') f) - 37.393) > 0.0001 THEN
    RAISE EXCEPTION 'FAIL upsert [m1 Rueckrechnung]: XAU %, XAG %',
      (SELECT f.rate FROM finance.fn_fx_rate('XAU', 'EUR', DATE '2026-05-05') f),
      (SELECT f.rate FROM finance.fn_fx_rate('XAG', 'EUR', DATE '2026-05-05') f);
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [m1 Metall invertiert, Rueckrechnung +-0,01]';

  -- [m2] gleicher Tag, gleiche Quelle, neuer Wert -> ueberschrieben (der Mischkurs zieht im Lauf des Tages nach)
  SELECT finance.fn_upsert_fx_rates('{"rows":[{"date":"2026-05-05","base":"XAU","quote":"EUR","rate":3240}]}'::jsonb) INTO v_result;
  IF (v_result->>'upserted')::int IS DISTINCT FROM 1
     OR (SELECT rate FROM finance.fx_rates WHERE quote_currency = 'XAU' AND as_of = DATE '2026-05-05') IS DISTINCT FROM round(1 / 3240.0, 10) THEN
    RAISE EXCEPTION 'FAIL upsert [m2 Nachziehen]: %', v_result;
  END IF;
  -- doppelte Zeile in einer Antwort bricht den Lauf nicht ab
  -- doppelte Zeile mit zwei Werten: eine Zeile, der hoechste gespeicherte Wert gewinnt (= der niedrigere Metallpreis)
  SELECT finance.fn_upsert_fx_rates('{"rows":[{"date":"2026-05-06","base":"XAU","quote":"EUR","rate":3250},
                                              {"date":"2026-05-06","base":"XAU","quote":"EUR","rate":3241}]}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'upserted')::int IS DISTINCT FROM 1
     OR (SELECT rate FROM finance.fx_rates WHERE quote_currency = 'XAU' AND as_of = DATE '2026-05-06') IS DISTINCT FROM round(1 / 3241.0, 10) THEN
    RAISE EXCEPTION 'FAIL upsert [m2 Dublette]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [m2 gleiche Quelle zieht nach, Dublette ok]';

  -- Tages-Modus mit unmoeglichem Kalendertag: alles verworfen, kein Cast-Fehler
  SELECT finance.fn_upsert_fx_rates('{"as_of":"2026-02-30","rates":{"USD":1.1}}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'upserted')::int IS DISTINCT FROM 0
     OR (v_result->>'skipped')::int IS DISTINCT FROM 1 OR v_result->>'as_of' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL upsert [Kalendertag]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [Tages-Modus: unmoeglicher Kalendertag verworfen]';

  -- [m3] nur Metalle kommen invertiert: Fremdwaehrung gegen EUR weiter abgelehnt; im Tages-Modus kein Metall
  PERFORM finance.fn_ensure_currency('USD');
  SELECT finance.fn_upsert_fx_rates('{"rows":[{"date":"2026-05-05","base":"USD","quote":"EUR","rate":0.9}]}'::jsonb) INTO v_result;
  IF (v_result->>'upserted')::int IS DISTINCT FROM 0 OR EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'USD') THEN
    RAISE EXCEPTION 'FAIL upsert [m3 USD/EUR invertiert]: %', v_result;
  END IF;
  SELECT finance.fn_upsert_fx_rates('{"as_of":"2026-05-07","rates":{"XAU":0.0003,"USD":1.1}}'::jsonb) INTO v_result;
  IF (v_result->>'upserted')::int IS DISTINCT FROM 1
     OR EXISTS (SELECT 1 FROM finance.fx_rates WHERE quote_currency = 'XAU' AND as_of = DATE '2026-05-07') THEN
    RAISE EXCEPTION 'FAIL upsert [m3 Metall im Tages-Feed]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [m3 nur Metalle invertiert, Tages-Feed ohne Metall]';

  -- [m4] Metall-Zeilen zaehlen weder fuer den Tages-Feed noch fuer die EZB-Ersatzquelle
  DELETE FROM finance.fx_rates;
  PERFORM finance.fn_upsert_fx_rates(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('date', v_utc::text, 'base', 'XAU', 'quote', 'EUR', 'rate', 3236.31))));
  IF (finance.fn_feed_refresh_due('fx')) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL upsert [m4]: Metall-Zeile von heute macht den Tages-Feed nicht aktuell';
  END IF;
  IF (finance.fn_fx_feed_gap()->>'never')::boolean IS DISTINCT FROM true OR finance.fn_fx_feed_gap()->>'stale_since' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL upsert [m4]: fn_fx_feed_gap zaehlt Metall-Zeilen: %', finance.fn_fx_feed_gap();
  END IF;
  -- auch eine Metall-Zeile fremder Quelle (Test-Fixture) zaehlt nicht als Waehrungs-Kurs von heute
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR', 'USD', 1.1, v_utc - 3, finance.fn_fx_feed_source()),
         ('EUR', 'USD', 1.1, v_utc - 4, finance.fn_fx_history_source()),
         ('EUR', 'XAG', 0.0267, v_utc, '__test__');
  IF (finance.fn_fx_history_due()->>'due')::boolean IS DISTINCT FROM true
     OR (finance.fn_fx_history_due()->>'from')::date IS DISTINCT FROM v_utc - 2 THEN
    RAISE EXCEPTION 'FAIL upsert [m4]: Metall-Zeile von heute verdeckt die EZB-Ersatzquelle: %', finance.fn_fx_history_due();
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [m4 Metall zaehlt nicht fuer Feed, Ausfall-Meldung, EZB-Ersatz]';
END $$;

ROLLBACK;
