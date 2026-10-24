-- tests/db/finance/test_recurring_payment_amount_check.sql
-- Multi-Member WS-3a (Backlog ii): struktureller CHECK (amount <> 0) auf finance.recurring_payments
-- (finance:V005). SIGNIERTER Betrag -> <> 0 (NICHT > 0; Ausgaben sind negativ). Der CHECK ist der
-- BACKSTOP unter den fn-Guards (haertet zugleich den WS-2 v_mag=0-Pfad). Der tool-fn faengt 0 schon
-- davor freundlich ab -> der CHECK schlaegt nie als Owner-Alert durch.
BEGIN;

DO $$
DECLARE
  v_acct INT;
  v_res  jsonb;
  v_sqlstate TEXT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rpc_cash__','cash','EUR','active') RETURNING id INTO v_acct;

  -- (1) Direkt-INSERT amount=0 -> CHECK-Verletzung (Backstop)
  BEGIN
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
      VALUES ('__rpc_zero__', v_acct, 0, 1, 'month', current_date, current_date, 'active');
    RAISE EXCEPTION 'FAIL [1]: amount=0 wurde akzeptiert -> CHECK (amount <> 0) fehlt';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [1: Direkt-INSERT amount=0 -> check_violation (struktureller Backstop)]';
  END;

  -- (1b) Negativer Betrag (Ausgabe) bleibt erlaubt -> der CHECK ist <> 0, nicht > 0
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__rpc_neg__', v_acct, -100, 1, 'month', current_date, current_date, 'active');
  RAISE NOTICE 'PASS [1b: negativer Betrag (Ausgabe) bleibt erlaubt (CHECK ist <> 0)]';

  -- (2) tool-fn fn_create_recurring_payment mit amount 0 -> freundliches {ok:false}, KEIN RAISE
  v_res := finance.fn_create_recurring_payment(jsonb_build_object(
    'account_id', v_acct, 'direction', 'expense', 'amount', 0,
    'schedule_unit', 'month', 'first_payment_date', to_char(current_date,'YYYY-MM-DD')));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [2]: fn_create_recurring_payment(amount 0) sollte {ok:false} liefern, got %', v_res; END IF;
  RAISE NOTICE 'PASS [2: tool-fn faengt amount 0 freundlich ab ({ok:false}, kein RAISE -> kein Owner-Alert)]';
END $$;

ROLLBACK;
