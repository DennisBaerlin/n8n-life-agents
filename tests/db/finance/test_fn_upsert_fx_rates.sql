-- tests/db/finance/test_fn_upsert_fx_rates.sql
-- fn_upsert_fx_rates: Kurs-Upsert NUR fuer Waehrungen aus fn_active_currencies()
-- (Objekt-Fixtures statt Currency-Seed-Fixtures — testet die fn_active_currencies-Integration).
-- Guards: Key-Existenz, numerisch+>0, Tages-Idempotenz, leeres rates-Objekt -> ok:false.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_as_of   DATE := DATE '2026-06-07';
  v_rate    NUMERIC;
  v_acct_id INT;
BEGIN

  -- Setup: USD FK-Eintrag noetig fuer account.currency-FK
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;

  -- TEST 1: Kein USD-Objekt -> USD-Kurs wird NICHT upserted (Early-Scope-Guard)
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object(
    'as_of', v_as_of::text,
    'rates', jsonb_build_object('USD', 1.08)
  )) INTO v_result;
  IF EXISTS (SELECT 1 FROM finance.fx_rates
             WHERE quote_currency = 'USD' AND as_of = v_as_of) THEN
    RAISE EXCEPTION 'FAIL upsert [kein Objekt]: USD darf nicht upserted werden ohne USD-Konto/Holding, result=%', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [kein USD-Objekt -> kein Upsert]';

  -- TEST 2: USD-Konto anlegen -> USD in fn_active_currencies -> Kurs wird upserted
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__test_usd_upsert__', 'cash', 'USD', 'active')
  RETURNING id INTO v_acct_id;

  SELECT finance.fn_upsert_fx_rates(jsonb_build_object(
    'as_of', v_as_of::text,
    'rates', jsonb_build_object('USD', 1.08, 'XXX', 5, 'BAD', 'n/a', 'ZER', 0)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL upsert [mit Objekt, ok]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fx_rates
                 WHERE base_currency = 'EUR' AND quote_currency = 'USD' AND as_of = v_as_of) THEN
    RAISE EXCEPTION 'FAIL upsert [mit Objekt, USD-Kurs]: USD-Kurs wurde nicht geschrieben';
  END IF;
  -- XXX/BAD/ZER duerfen NICHT geschrieben worden sein
  IF EXISTS (SELECT 1 FROM finance.fx_rates
             WHERE quote_currency IN ('XXX','BAD','ZER') AND as_of = v_as_of) THEN
    RAISE EXCEPTION 'FAIL upsert [skip untracked/0/non-numeric]: ungueltige Kurse wurden geschrieben';
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [USD-Objekt -> Kurs upserted; XXX/BAD/ZER skip]';

  -- Assert: USD-Rate korrekt
  SELECT rate INTO v_rate FROM finance.fx_rates
  WHERE base_currency = 'EUR' AND quote_currency = 'USD' AND as_of = v_as_of;
  IF v_rate IS DISTINCT FROM 1.08 THEN
    RAISE EXCEPTION 'FAIL upsert [USD rate]: erwartet 1.08, got %', v_rate;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [USD rate korrekt gespeichert]';

  -- TEST 3: Idempotenz — gleicher as_of, neuer Kurs -> UPDATE, kein zweites INSERT
  SELECT finance.fn_upsert_fx_rates(jsonb_build_object(
    'as_of', v_as_of::text,
    'rates', jsonb_build_object('USD', 1.09)
  )) INTO v_result;
  SELECT rate INTO v_rate FROM finance.fx_rates
  WHERE base_currency = 'EUR' AND quote_currency = 'USD' AND as_of = v_as_of;
  IF v_rate IS DISTINCT FROM 1.09 THEN
    RAISE EXCEPTION 'FAIL upsert [Idempotenz update]: erwartet 1.09, got %', v_rate;
  END IF;
  IF (SELECT count(*) FROM finance.fx_rates
      WHERE base_currency = 'EUR' AND quote_currency = 'USD' AND as_of = v_as_of) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL upsert [Idempotenz: keine Dublette]: mehr als 1 Zeile fuer (EUR,USD,%)', v_as_of;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [Tages-Idempotenz: UPDATE statt INSERT]';

  -- TEST 4: fehlendes rates-Objekt -> ok:false, kein RAISE
  SELECT finance.fn_upsert_fx_rates('{"as_of":"2026-06-07"}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL upsert [kein rates-Objekt]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_upsert_fx_rates [kein rates-Objekt -> ok:false]';

END $$;

ROLLBACK;
