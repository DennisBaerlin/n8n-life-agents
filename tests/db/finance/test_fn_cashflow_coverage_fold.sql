-- tests/db/finance/test_fn_cashflow_coverage_fold.sql
-- finance.fn_cashflow_coverage_fold (Audit Paket 3): der EINE cashflow_coverage-Sofort-Hinweis der Write-fns
-- fn_create_recurring_payment / fn_set_recurring_payment. Feuert bei monthly_free < 0 (Pflichtausgaben = Konsum +
-- Kreditraten > Einnahmen), auch OHNE Einnahmen (letztes Gehalt beendet); Sparraten zaehlen nicht. Gelatcht ueber
-- core.fn_should_notify, Re-Arm bei Erholung. Leere Quelle (keine laufende Zahlung) = neutral.
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';   -- kontrollierter Cashflow (nur in dieser Transaktion)

DO $$
DECLARE
  v_acct int; v_depot int; v_rp int; r jsonb;
BEGIN
  -- (0) leer -> neutral
  IF finance.fn_cashflow_coverage_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [0]: leere Quelle muss neutral sein, got %', finance.fn_cashflow_coverage_fold(); END IF;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ccf_giro__','cash','EUR','active') RETURNING id INTO v_acct;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__ccf_depot__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;

  -- (1) Einnahmen 2000, Konsum 500, ETF-Sparplan 1800 -> frei +1500 -> kein Hinweis (Sparen ist keine Pflicht)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__ccf_salary__', v_acct, 2000, 'month', current_date, current_date),
    ('__ccf_rent__',   v_acct, -500, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__ccf_etf__', v_acct, -1800, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__ccf_plan__', v_depot, 'CCFW', 'World', v_rp);
  IF finance.fn_cashflow_coverage_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1]: frei +1500 darf keinen Hinweis geben, got %', finance.fn_cashflow_coverage_fold(); END IF;
  RAISE NOTICE 'PASS [1] Sparplan ist keine Fixkosten -> kein Hinweis';

  -- (2) Code-Review: einziges Gehalt endet -> Einnahmen 0, Pflicht 500 -> Hinweis mit monthly_free -500
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__ccf_salary__';
  r := finance.fn_cashflow_coverage_fold();
  IF (r->'cashflow_coverage'->>'monthly_free')::numeric IS DISTINCT FROM -500.00
     OR COALESCE(r->'cashflow_coverage'->>'note', '') = '' THEN
    RAISE EXCEPTION 'FAIL [2]: ohne Einnahmen muss der Hinweis kommen (frei -500), got %', r; END IF;
  RAISE NOTICE 'PASS [2] Pflichtausgaben ohne Einnahmen -> Hinweis';

  -- (3) Latch: zweiter Aufruf im selben Zustand -> keine erneute Meldung
  IF finance.fn_cashflow_coverage_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3]: gelatcht, zweiter Aufruf darf nicht erneut melden'; END IF;

  -- (4) Erholung -> Re-Arm -> erneutes Defizit meldet wieder
  UPDATE finance.recurring_payments SET status = 'active' WHERE name = '__ccf_salary__';
  PERFORM finance.fn_cashflow_coverage_fold();
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name = '__ccf_salary__';
  IF NOT (finance.fn_cashflow_coverage_fold() ? 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [4]: nach Erholung muss ein neues Defizit wieder melden (Re-Arm)'; END IF;
  RAISE NOTICE 'PASS [3/4] Latch + Re-Arm';
END $$;

-- (5) Alltagsausgaben aus dem Kontoauszug: ohne laufende Zahlung bleibt es neutral; frei genau 0 meldet nicht; Gehalt =
--     Miete, nur der Alltag macht das Defizit -> Hinweis mit monthly_free = Alltag.
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_acct int; v_ev numeric; r jsonb;
BEGIN
  UPDATE finance.recurring_payments SET status = 'paused' WHERE name LIKE '\_\_ccf\_%';
  PERFORM core.fn_notify_resolve('finance', 'cashflow_coverage');
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ccf5_giro__','cash','EUR','active') RETURNING id INTO v_acct;
  INSERT INTO finance.bank_statements (account_id, period_start, period_end, opening_balance, closing_balance, currency,
                                       line_count, matched_count, unmatched_out, unmatched_in, prev_last_reconciled_at)
  VALUES (v_acct, t - 34, t - 5, 1300, 1000, 'EUR', 5, 0, -300, 0, NULL);
  SELECT monthly_everyday INTO v_ev FROM finance.fn_household_everyday_month();
  IF finance.fn_cashflow_coverage_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5a]: ohne laufende Zahlung neutral, auch mit Alltag, got %', finance.fn_cashflow_coverage_fold(); END IF;

  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__ccf5_salary__', v_acct, 500 - v_ev, 'month', t, t),
    ('__ccf5_rent__',   v_acct, -500, 'month', t, t);
  IF finance.fn_cashflow_coverage_fold() <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5b]: frei genau 0 meldet nicht, got %', finance.fn_cashflow_coverage_fold(); END IF;

  UPDATE finance.recurring_payments SET amount = 500 WHERE name = '__ccf5_salary__';
  r := finance.fn_cashflow_coverage_fold();
  IF (r->'cashflow_coverage'->>'monthly_free')::numeric IS DISTINCT FROM v_ev
     -- der Text fuers Modell nennt beide Betraege positiv
     OR r->'cashflow_coverage'->>'note' NOT LIKE '%(about ' || abs(v_ev) || ' EUR/month)%'
     OR r->'cashflow_coverage'->>'note' NOT LIKE '%exceed income by about ' || abs(v_ev) || ' EUR/month%' THEN
    RAISE EXCEPTION 'FAIL [5c]: Defizit nur aus dem Alltag, monthly_free %, got %', v_ev, r; END IF;
  RAISE NOTICE 'PASS [5] Alltag im Defizit, Grenze 0, leere Quelle neutral';
END $$;

ROLLBACK;
