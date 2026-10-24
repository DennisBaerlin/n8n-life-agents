-- tests/db/career/test_fn_runway.sql
-- career.fn_runway (WS-5 Runway-Bruecke, Consumer-Seite): rechnet die Runway (liquide Mittel /
-- (Monats-Ausgaben - erwartetes Notfall-Einkommen)) vs Probezeit-Laenge. DB rechnet, "LLM rechnet nicht".
-- DOPPEL-GUARD auf das OPTIONALE finance-Paket: core.fn_package_active('finance') UND
-- to_regprocedure('finance.fn_liquidity_snapshot()') -> bei Miss graceful NULL (Zeile entfaellt), nie RAISE.
-- Math-Assertions self-konsistent gegen den realen Snapshot (robust gegen Bestands-Cash/-Ausgaben).
BEGIN;
DO $$
DECLARE
  snap jsonb; res jsonb;
  v_cash numeric; v_exp numeric; v_expected int;
  v_cashacct int;
  v_plan jsonb;
BEGIN
  -- finance als aktives Paket registrieren (Guard 1) + dominante Cash/Ausgaben seeden
  INSERT INTO core.package_registry (package, status) VALUES ('finance','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rw_cash__','cash','EUR','active') RETURNING id INTO v_cashacct;
  UPDATE finance.account_balances SET balance = 100000 WHERE account_id = v_cashacct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__rw_exp__', v_cashacct, -4000, 'month', current_date, current_date);

  snap   := finance.fn_liquidity_snapshot();
  v_cash := (snap->>'cash_eur')::numeric;
  v_exp  := (snap->>'monthly_expenses_eur')::numeric;
  IF v_exp <= 0 THEN RAISE EXCEPTION 'FAIL [setup]: monthly_expenses_eur muss > 0 sein, got %', v_exp; END IF;

  -- ---------- TEST 1: Default-Szenario (probation 6, gap 0) -> runway = floor(cash/exp) ----------
  v_plan := jsonb_build_object('transition', jsonb_build_object('probation_months', 6));
  res := career.fn_runway(v_plan);
  IF res IS NULL THEN RAISE EXCEPTION 'FAIL [1]: res NULL trotz aktivem finance + Daten'; END IF;
  v_expected := floor(v_cash / v_exp)::int;
  IF (res->>'runway_months')::int <> v_expected THEN RAISE EXCEPTION 'FAIL [1 math]: runway % erwartet %', res->>'runway_months', v_expected; END IF;
  IF (res->>'probation_months')::int <> 6 THEN RAISE EXCEPTION 'FAIL [1 probation]: %', res; END IF;
  IF (res->>'covers')::boolean IS DISTINCT FROM (v_expected >= 6) THEN RAISE EXCEPTION 'FAIL [1 covers]: %', res; END IF;
  RAISE NOTICE 'PASS [1] Default probation 6 / gap 0 -> runway floor(cash/exp) + covers';

  -- ---------- TEST 2: Notfall-Einkommen reduziert den Burn ----------
  v_plan := jsonb_build_object('transition', jsonb_build_object('probation_months', 6, 'expected_gap_income_eur', 1000));
  res := career.fn_runway(v_plan);
  v_expected := floor(v_cash / (v_exp - 1000))::int;
  IF (res->>'runway_months')::int <> v_expected THEN RAISE EXCEPTION 'FAIL [2 gap income]: runway % erwartet %', res->>'runway_months', v_expected; END IF;
  RAISE NOTICE 'PASS [2] Notfall-Einkommen -> effective_burn = exp - gap';

  -- ---------- TEST 3: fehlende transition -> Default probation 6 / gap 0 ----------
  res := career.fn_runway('{}'::jsonb);
  IF (res->>'probation_months')::int <> 6 THEN RAISE EXCEPTION 'FAIL [3 default probation]: %', res; END IF;
  IF (res->>'runway_months')::int <> floor(v_cash / v_exp)::int THEN RAISE EXCEPTION 'FAIL [3 default gap 0]: %', res; END IF;
  RAISE NOTICE 'PASS [3] fehlende transition -> Default probation 6 / gap 0';

  -- ---------- TEST 4: effective_burn <= 0 -> runway_months NULL (unbegrenzt), kein Div-by-0 ----------
  v_plan := jsonb_build_object('transition', jsonb_build_object('expected_gap_income_eur', v_exp + 1000));
  res := career.fn_runway(v_plan);
  IF res IS NULL THEN RAISE EXCEPTION 'FAIL [4]: res NULL'; END IF;
  IF res->>'runway_months' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 unbegrenzt]: runway_months nicht NULL trotz gap>exp: %', res; END IF;
  IF (res->>'covers')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 covers bei unbegrenzt]: %', res; END IF;
  RAISE NOTICE 'PASS [4] gap >= Ausgaben -> runway_months NULL (unbegrenzt), covers=true, kein Div/0';

  -- ---------- TEST 4b (WP-3c): has_fx_gap wird aus dem Snapshot durchgereicht ----------
  DECLARE v_krw int; BEGIN
    res := career.fn_runway('{}'::jsonb);
    IF (res->>'has_fx_gap')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [4b baseline]: has_fx_gap erwartet false (nur EUR-Konten), got %', res->>'has_fx_gap'; END IF;
    INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rw_krw__','cash','KRW','active') RETURNING id INTO v_krw;
    UPDATE finance.account_balances SET balance = 1450000 WHERE account_id = v_krw;   -- KRW ohne fx_rate
    res := career.fn_runway('{}'::jsonb);
    IF (res->>'has_fx_gap')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [4b passthrough]: has_fx_gap erwartet true (KRW-Cash ohne Kurs), got %', res->>'has_fx_gap'; END IF;
    RAISE NOTICE 'PASS [4b] has_fx_gap aus Snapshot durchgereicht (false ohne / true mit Fremdwaehrungs-Luecke)';
  END;

  -- ---------- TEST 5 (Guard a): finance inaktiv -> graceful NULL, kein RAISE ----------
  UPDATE core.package_registry SET status='inactive' WHERE package='finance';
  IF career.fn_runway('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 inactive]: nicht NULL'; END IF;
  UPDATE core.package_registry SET status='active' WHERE package='finance';
  RAISE NOTICE 'PASS [5] finance inaktiv -> graceful NULL (Guard fn_package_active)';

  -- ---------- TEST 6 (Guard b): snapshot-fn fehlt -> graceful NULL, kein RAISE ----------
  DROP FUNCTION finance.fn_liquidity_snapshot();
  IF career.fn_runway('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [6 fn missing]: nicht NULL'; END IF;
  RAISE NOTICE 'PASS [6] snapshot-fn fehlt -> graceful NULL (Guard to_regprocedure)';

  RAISE NOTICE 'PASS test_fn_runway';
END $$;
ROLLBACK;
