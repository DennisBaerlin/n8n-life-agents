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

  -- TEST 3: KRW -> minor_unit=0 (zero-decimal)
  SELECT finance.fn_ensure_currency('KRW') INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [KRW]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT minor_unit INTO v_minor_unit FROM finance.currencies WHERE code = 'KRW';
  IF v_minor_unit IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_ensure_currency [KRW minor_unit]: erwartet 0 (zero-decimal), got %', v_minor_unit;
  END IF;
  RAISE NOTICE 'PASS fn_ensure_currency [KRW: minor_unit=0]';

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

END $$;

ROLLBACK;
