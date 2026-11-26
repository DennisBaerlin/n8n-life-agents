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

ROLLBACK;
