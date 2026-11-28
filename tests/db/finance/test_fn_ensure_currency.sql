-- tests/db/finance/test_fn_ensure_currency.sql
-- fn_ensure_currency(p_code): Auto-Registrierung unbekannter ISO-4217-Codes in finance_currencies.
-- Guards: ^[A-Z]{3}$-Regex, zero-decimal-Liste, Idempotenz (ON CONFLICT DO NOTHING).
BEGIN;

DO $$
DECLARE
  v_result     JSONB;
  v_minor_unit SMALLINT;
BEGIN

  -- TEST 1: Regex-Guard — Kleinbuchstaben abgewiesen
  SELECT finance.fn_ensure_currency('usd') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [lowercase]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [lowercase -> ok:false]';

  SELECT finance.fn_ensure_currency('US') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [2-Zeichen]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [2-Zeichen -> ok:false]';

  SELECT finance.fn_ensure_currency('') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [leer]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [leer -> ok:false]';

  SELECT finance.fn_ensure_currency(NULL) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [NULL]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [NULL -> ok:false]';

  -- TEST 2: Neue Waehrung USD anlegen (Default minor_unit=2)
  SELECT finance.fn_ensure_currency('USD') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [USD insert]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.currencies WHERE code = 'USD') THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [USD]: Zeile nicht in finance_currencies';
  END IF;
  SELECT minor_unit INTO v_minor_unit FROM finance.currencies WHERE code = 'USD';
  IF v_minor_unit IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [USD minor_unit]: erwartet 2, got %', v_minor_unit;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [USD: angelegt, minor_unit=2]';

  -- TEST 3: CLP -> minor_unit=0 (zero-decimal)
  SELECT finance.fn_ensure_currency('CLP') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [CLP]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT minor_unit INTO v_minor_unit FROM finance.currencies WHERE code = 'CLP';
  IF v_minor_unit IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [CLP minor_unit]: erwartet 0 (zero-decimal), got %', v_minor_unit;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [CLP: minor_unit=0]';

  -- TEST 4: JPY -> minor_unit=0
  SELECT finance.fn_ensure_currency('JPY') INTO v_result;
  SELECT minor_unit INTO v_minor_unit FROM finance.currencies WHERE code = 'JPY';
  IF v_minor_unit IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [JPY minor_unit]: erwartet 0, got %', v_minor_unit;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [JPY: minor_unit=0]';

  -- TEST 5: Idempotenz (USD zweimal -> kein Duplikat, ok:true)
  SELECT finance.fn_ensure_currency('USD') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [Idempotenz]: zweiter Call erwartet ok=true, got %', v_result;
  END IF;
  IF (SELECT count(*) FROM finance.currencies WHERE code = 'USD') IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [Idempotenz]: mehr als 1 Zeile in finance_currencies fuer USD';
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [Idempotenz: ON CONFLICT DO NOTHING]';

  -- TEST 6 [22]: volle ISO-4217-Ausnahmen (SIX List One): 3 Stellen, 4 Stellen, UYI 0
  PERFORM finance.fn_ensure_currency('KWD');
  PERFORM finance.fn_ensure_currency('CLF');
  PERFORM finance.fn_ensure_currency('UYI');
  PERFORM finance.fn_ensure_currency('UYW');
  IF (SELECT minor_unit FROM finance.currencies WHERE code = 'KWD') IS DISTINCT FROM 3::smallint
     OR (SELECT minor_unit FROM finance.currencies WHERE code = 'CLF') IS DISTINCT FROM 4::smallint
     OR (SELECT minor_unit FROM finance.currencies WHERE code = 'UYW') IS DISTINCT FROM 4::smallint
     OR (SELECT minor_unit FROM finance.currencies WHERE code = 'UYI') IS DISTINCT FROM 0::smallint THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [22 ISO-Ausnahmen]: KWD/CLF/UYW/UYI = %',
      (SELECT jsonb_object_agg(code, minor_unit) FROM finance.currencies WHERE code IN ('KWD','CLF','UYW','UYI'));
  END IF;
  -- dieselbe Regel als Mengen-Helfer (fn_upsert_fx_rates registriert alle Feed-Waehrungen darueber)
  IF finance.fn_currency_minor_unit('BHD') IS DISTINCT FROM 3::smallint
     OR finance.fn_currency_minor_unit('JPY') IS DISTINCT FROM 0::smallint
     OR finance.fn_currency_minor_unit('GGP') IS DISTINCT FROM 2::smallint THEN
    RAISE EXCEPTION 'FAIL fn_currency_minor_unit [BHD 3, JPY 0, Nicht-ISO 2]';
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [22: KWD 3, CLF/UYW 4, UYI 0, Nicht-ISO 2]';

END $$;

ROLLBACK;
