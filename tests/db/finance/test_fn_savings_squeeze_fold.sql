-- tests/db/finance/test_fn_savings_squeeze_fold.sql
-- finance.fn_savings_squeeze_fold: der EINE savings_squeeze-Sofort-Hinweis der Sparraten-Write-fns
-- (fn_create_savings_goal / fn_set_savings_goal / fn_set_savings_plan). Feuert bei monthly_income > 0 und
-- monthly_account_change < 0 (Sparraten leeren das Girokonto). Gelatcht ueber core.fn_should_notify (TTL 24h),
-- Re-Arm bei Erholung (account_change >= 0). Ohne Einnahmen: weder Hinweis noch Re-Arm (das meldet cashflow_coverage).
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';   -- kontrollierter Cashflow (nur in dieser Transaktion)

DO $$
DECLARE
  v_acct int; v_depot int; v_rp int; r jsonb;
BEGIN
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');   -- sauberer Latch-Start

  -- (0) leer (keine Einnahmen) -> neutral
  IF finance.fn_savings_squeeze_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [0]: leere Quelle muss neutral sein, got %', finance.fn_savings_squeeze_fold(); END IF;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ssf_giro__','cash','EUR','active') RETURNING id INTO v_acct;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__ssf_depot__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;

  -- (1) Einnahmen 2000, Konsum 500, ETF-Sparplan 1800 -> frei +1500, Kontoveraenderung -300 -> Hinweis
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__ssf_salary__', v_acct, 2000, 'month', current_date, current_date),
    ('__ssf_rent__',   v_acct, -500, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__ssf_etf__', v_acct, -1800, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__ssf_plan__', v_depot, 'SSFW', 'World', v_rp);
  r := finance.fn_savings_squeeze_fold();
  IF (r->'savings_squeeze'->>'account_change')::numeric IS DISTINCT FROM -300.00
     OR COALESCE(r->'savings_squeeze'->>'note', '') NOT ILIKE '%savings rates exceed%' THEN
    RAISE EXCEPTION 'FAIL [1]: Sparraten > frei -> Hinweis mit account_change -300, got %', r; END IF;
  RAISE NOTICE 'PASS [1] Sparraten leeren das Girokonto -> Hinweis';

  -- (2) Latch: zweiter Aufruf im selben Zustand -> keine erneute Meldung
  IF finance.fn_savings_squeeze_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [2]: gelatcht, zweiter Aufruf darf nicht erneut melden'; END IF;
  RAISE NOTICE 'PASS [2] Latch';

  -- (3) ohne Einnahmen: kein Hinweis UND kein Re-Arm (Latch bleibt -> nach Rueckkehr des Gehalts weiter still)
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__ssf_salary__';
  IF finance.fn_savings_squeeze_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3a]: ohne Einnahmen kein savings_squeeze'; END IF;
  UPDATE finance.recurring_payments SET status = 'active' WHERE name = '__ssf_salary__';
  IF finance.fn_savings_squeeze_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3b]: ohne Einnahmen darf der Latch nicht re-armt werden'; END IF;
  RAISE NOTICE 'PASS [3] ohne Einnahmen: weder Hinweis noch Re-Arm';

  -- (4) Erholung (Sparplan 1000 -> Kontoveraenderung +500) re-armt; erneuter Anstieg meldet sofort wieder
  UPDATE finance.recurring_payments SET amount = -1000 WHERE id = v_rp;
  IF finance.fn_savings_squeeze_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4a]: gesunder Stand darf nicht melden'; END IF;
  UPDATE finance.recurring_payments SET amount = -1800 WHERE id = v_rp;
  IF NOT (finance.fn_savings_squeeze_fold() ? 'savings_squeeze') THEN
    RAISE EXCEPTION 'FAIL [4b]: nach Erholung muss ein neuer Engpass innerhalb 24h wieder melden (Re-Arm)'; END IF;
  RAISE NOTICE 'PASS [4] Re-Arm bei Erholung';

  -- (5) frei schon negativ (Miete 2500) -> eigener Text "already exceed"
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');
  UPDATE finance.recurring_payments SET amount = -2500 WHERE name = '__ssf_rent__';
  r := finance.fn_savings_squeeze_fold();
  IF (r->'savings_squeeze'->>'account_change')::numeric IS DISTINCT FROM -2300.00
     OR COALESCE(r->'savings_squeeze'->>'note', '') NOT ILIKE '%already exceed%' THEN
    RAISE EXCEPTION 'FAIL [5]: frei < 0 -> Text already exceed + account_change -2300, got %', r; END IF;
  RAISE NOTICE 'PASS [5] Pflicht-Defizit -> eigener Text';
END $$;

ROLLBACK;
