-- tests/db/finance/test_schedule_dom_domain.sql
-- WP-2b: schedule_day_of_month-Domaene (1-28 | -1 | NULL). Beweist die DREI Adressen der Invariante:
--   (1) fn_valid_schedule_dom (IMMUTABLE Bool-Helper, freundlicher Guard-Kern),
--   (2) der V012-CHECK auf den tragenden Tabellen (struktureller Backstop, direktes DML; Kredit/Versicherung tragen den
--       Tag seit finance:V026/V027 nur noch an der rp),
--   (3) der freundliche {ok:false}-Guard in einer repraesentativen Schreib-fn.
-- Regression gegen den fixed-dom-Overflow (29/30/31 overflowt kurze Monate -> Kachel-Bruch, arch-surfaced).
BEGIN;
DO $$
DECLARE v_acct INT; v_res JSONB;
BEGIN
  -- ===== (1) fn_valid_schedule_dom: Domaenen-Bool =====
  IF NOT (finance.fn_valid_schedule_dom(NULL) AND finance.fn_valid_schedule_dom(-1)
          AND finance.fn_valid_schedule_dom(1) AND finance.fn_valid_schedule_dom(28)) THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_dom]: gueltiger Tag (NULL/-1/1/28) abgelehnt'; END IF;
  IF finance.fn_valid_schedule_dom(0) OR finance.fn_valid_schedule_dom(29)
     OR finance.fn_valid_schedule_dom(30) OR finance.fn_valid_schedule_dom(31) THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_dom]: Domaenen-fremder Tag (0/29/30/31) akzeptiert'; END IF;
  RAISE NOTICE 'PASS [fn_valid_schedule_dom: 1-28|-1|NULL true, 0/29/30/31 false]';

  -- Setup: ein Konto fuer die FKs.
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__dom_acct__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;

  -- ===== (2) V012-CHECK weist dom=30 ab (direktes DML -> check_violation) =====
  BEGIN
    INSERT INTO finance.account_interest_rates
      (account_id, annual_rate, schedule_interval, schedule_unit, schedule_day_of_month, valid_from)
      VALUES (v_acct, 2, 1, 'month', 30, DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL [CHECK air]: account_interest_rates akzeptierte schedule_day_of_month=30';
  EXCEPTION WHEN check_violation THEN NULL; END;

  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_interval, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
      VALUES ('__dom_rp__', v_acct, 100, 1, 'month', 30, DATE '2026-01-01', DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL [CHECK rp]: recurring_payments akzeptierte schedule_day_of_month=30';
  EXCEPTION WHEN check_violation THEN NULL; END;

  -- (Kredit/Versicherung tragen seit finance:V026/V027 keinen eigenen Abbuchungstag mehr -- der steht nur an der rp.)
  RAISE NOTICE 'PASS [V012-CHECK: dom=30 an account_interest_rates + recurring_payments abgewiesen]';

  -- ===== (2b) -1 (Monatsletzter) und 28 werden akzeptiert (Guard ueber-rejected nicht) =====
  INSERT INTO finance.recurring_payments
    (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('__dom_rp_m1__', v_acct, 100, 'month', -1, DATE '2026-01-01', DATE '2026-01-01');
  INSERT INTO finance.recurring_payments
    (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('__dom_rp_28__', v_acct, 100, 'month', 28, DATE '2026-01-01', DATE '2026-01-01');
  RAISE NOTICE 'PASS [V012-CHECK: -1 und 28 akzeptiert]';

  -- ===== (3) freundlicher {ok:false} aus einer repraesentativen Schreib-fn (dom=30) =====
  v_res := finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__dom_fn__','account_id',v_acct,'direction','expense','amount',100,
    'schedule_unit','month','schedule_day_of_month',30,'first_payment_date','2026-01-01'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [fn dom=30]: fn_create_recurring_payment akzeptierte dom=30 (erwartet ok:false), got %', v_res; END IF;
  IF v_res->>'reason' IS NULL THEN
    RAISE EXCEPTION 'FAIL [fn dom=30]: ok:false ohne reason'; END IF;
  RAISE NOTICE 'PASS [fn_create_recurring_payment dom=30 -> ok:false (%)]', v_res->>'reason';

  -- ===== (3b) dom=-1 wird von der Schreib-fn akzeptiert (kein Ueber-Reject) =====
  v_res := finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__dom_fn_ok__','account_id',v_acct,'direction','expense','amount',100,
    'schedule_unit','month','schedule_day_of_month',-1,'first_payment_date','2026-01-01'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [fn dom=-1]: fn_create_recurring_payment lehnte gueltigen dom=-1 ab, got %', v_res; END IF;
  RAISE NOTICE 'PASS [fn_create_recurring_payment dom=-1 -> ok:true]';

  -- ===== (4) Feste Monatstage: fn_valid_schedule_days + CHECKs auf recurring_payments und accounts =====
  IF NOT (finance.fn_valid_schedule_days(NULL) AND finance.fn_valid_schedule_days('{}')
          AND finance.fn_valid_schedule_days('{2,9,16,23}') AND finance.fn_valid_schedule_days('{1}')) THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_days]: gueltige Liste abgelehnt'; END IF;
  IF finance.fn_valid_schedule_days('{9,2}') OR finance.fn_valid_schedule_days('{2,2}')
     OR finance.fn_valid_schedule_days('{0,5}') OR finance.fn_valid_schedule_days('{5,29}')
     OR finance.fn_valid_schedule_days('{2,NULL}') OR finance.fn_valid_schedule_days('{{2,9},{16,23}}') THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_days]: unsortiert/doppelt/ausserhalb 1-28/NULL/2-dim akzeptiert'; END IF;
  RAISE NOTICE 'PASS [fn_valid_schedule_days: kanonisch 1-28, leer und NULL ok]';

  -- rp: Tage nur bei unit=month, ohne Einzeltag, mindestens 2
  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
      VALUES ('__days_week__', v_acct, 100, 'week', '{2,16}', DATE '2026-01-02', DATE '2026-01-02');
    RAISE EXCEPTION 'FAIL [CHECK rp days]: Tage bei unit=week akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_unit, schedule_day_of_month, schedule_days_of_month, first_payment_date, valid_from)
      VALUES ('__days_dom__', v_acct, 100, 'month', 2, '{2,16}', DATE '2026-01-02', DATE '2026-01-02');
    RAISE EXCEPTION 'FAIL [CHECK rp days]: Tage + Einzeltag akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
      VALUES ('__days_one__', v_acct, 100, 'month', '{2}', DATE '2026-01-02', DATE '2026-01-02');
    RAISE EXCEPTION 'FAIL [CHECK rp days]: Einzeltag als Liste akzeptiert (gehoert in schedule_day_of_month)';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
      VALUES ('__days_unsorted__', v_acct, 100, 'month', '{16,2}', DATE '2026-01-02', DATE '2026-01-02');
    RAISE EXCEPTION 'FAIL [CHECK rp days]: unsortierte Liste akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  INSERT INTO finance.recurring_payments
    (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
    VALUES ('__days_ok__', v_acct, 100, 'month', '{2,9,16,23}', DATE '2026-01-02', DATE '2026-01-02');
  RAISE NOTICE 'PASS [CHECK rp schedule_days_of_month]';

  -- accounts.plan_execution_days: nur auf Depots; '{}' = kein fester Kalender
  BEGIN
    UPDATE finance.accounts SET plan_execution_days = '{2,16}' WHERE id = v_acct;
    RAISE EXCEPTION 'FAIL [CHECK accounts plan_execution_days]: Kalender auf einem cash-Konto akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  DECLARE v_dep INT; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__days_depot__', 'stocks_depot', 'EUR', 'active', v_acct) RETURNING id INTO v_dep;
    UPDATE finance.accounts SET plan_execution_days = '{}' WHERE id = v_dep;
    UPDATE finance.accounts SET plan_execution_days = '{1,15}' WHERE id = v_dep;
    BEGIN
      UPDATE finance.accounts SET plan_execution_days = '{15,1}' WHERE id = v_dep;
      RAISE EXCEPTION 'FAIL [CHECK accounts plan_execution_days]: unsortiert akzeptiert';
    EXCEPTION WHEN check_violation THEN NULL; END;
  END;
  RAISE NOTICE 'PASS [CHECK accounts plan_execution_days: nur Depots, kanonisch, leer erlaubt]';
END $$;

-- ===== (5) -2 = vorletzter Tag des Monats (Live-Befund 2026-10-24): Zahlungen ja, Zins-Konditionen nein =====
DO $$
DECLARE v_acct INT; v_res JSONB; v_reason TEXT;
BEGIN
  IF NOT finance.fn_valid_schedule_dom(-2) THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_dom]: -2 (vorletzter Tag) abgelehnt'; END IF;
  IF finance.fn_valid_schedule_dom(-3) THEN
    RAISE EXCEPTION 'FAIL [fn_valid_schedule_dom]: -3 akzeptiert'; END IF;
  -- Reason-fn = die EINE Adresse des Fehlertexts
  IF finance.fn_schedule_dom_reason(-2) IS NOT NULL OR finance.fn_schedule_dom_reason(NULL) IS NOT NULL
     OR finance.fn_schedule_dom_reason(28) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [fn_schedule_dom_reason]: gueltiger Tag mit Grund'; END IF;
  v_reason := finance.fn_schedule_dom_reason(30);
  IF v_reason IS NULL OR v_reason NOT LIKE '%-2%' OR v_reason NOT LIKE '%-1%' THEN
    RAISE EXCEPTION 'FAIL [fn_schedule_dom_reason]: 30 ohne Grund oder ohne -1/-2-Hinweis, got %', v_reason; END IF;
  RAISE NOTICE 'PASS [-2 gueltig, -3 ungueltig, Reason-fn]';

  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__dom2_acct__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;
  -- CHECK: rp nimmt -2, account_interest_rates nicht (Zins-Raster kennt nur -1)
  INSERT INTO finance.recurring_payments
    (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('__dom2_rp__', v_acct, 100, 'month', -2, DATE '2026-01-01', DATE '2026-01-01');

  BEGIN
    INSERT INTO finance.account_interest_rates
      (account_id, annual_rate, schedule_interval, schedule_unit, schedule_day_of_month, valid_from)
      VALUES (v_acct, 2, 1, 'month', -2, DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL [CHECK air]: account_interest_rates akzeptierte -2';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.recurring_payments
      (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
      VALUES ('__dom3_rp__', v_acct, 100, 'month', -3, DATE '2026-01-01', DATE '2026-01-01');
    RAISE EXCEPTION 'FAIL [CHECK rp]: -3 akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS [CHECK: -2 auf rp, nicht auf account_interest_rates; -3 nirgends]';

  -- Schreib-fns: Dauerauftrag mit -2 ok; Zins-Konditionen mit -2 -> ok:false (eigener Grund)
  v_res := finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__dom2_fn__','account_id',v_acct,'direction','expense','amount',100,
    'schedule_unit','month','schedule_day_of_month',-2,'first_payment_date','2026-01-30'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [fn dom=-2]: fn_create_recurring_payment lehnte -2 ab, got %', v_res; END IF;
  v_reason := finance.fn_interest_terms_reason('month', (-2)::smallint, NULL, NULL);
  IF v_reason IS NULL OR v_reason NOT ILIKE '%interest%' THEN
    RAISE EXCEPTION 'FAIL [fn_interest_terms_reason]: -2 fuer Zins nicht abgelehnt, got %', v_reason; END IF;
  RAISE NOTICE 'PASS [Schreib-fn -2 ok; Zins-Konditionen -2 abgelehnt (%)]', v_reason;
END $$;
ROLLBACK;
