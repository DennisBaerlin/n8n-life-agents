-- tests/db/finance/test_fn_recurring_chain_ended.sql
-- finance.fn_recurring_chain_ended(rp_id, on): beendet = kein Glied der Kette laeuft am Tag oder kommt noch.
--   [1] laufendes Glied ohne Ende -> false          [2] Ende erreicht -> true, Ende erst morgen -> false
--   [3] Start in der Zukunft -> false               [4] beendeter Vorgaenger + leerer Kopf in der Zukunft -> true
--   [5] beendeter Vorgaenger + laufender Kopf -> false (jedes Glied der Kette gefragt)   [6] unbekannte id -> false
BEGIN;

DO $$
DECLARE v_t DATE := current_date; v_acct INT; v_a INT; v_b INT; v_c INT; v_d INT; v_e INT; v_f INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_rce_acct__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_rce_a__', v_acct, -10, 'month', v_t - 60, v_t - 60, NULL) RETURNING id INTO v_a;
  IF finance.fn_recurring_chain_ended(v_a, v_t) THEN RAISE EXCEPTION 'FAIL [1] laufend ohne Ende gilt als beendet'; END IF;

  UPDATE finance.recurring_payments SET valid_to = v_t, status = 'paused' WHERE id = v_a;
  IF NOT finance.fn_recurring_chain_ended(v_a, v_t) OR finance.fn_recurring_chain_ended(v_a, v_t - 1) THEN
    RAISE EXCEPTION 'FAIL [2] Ende heute: heute % (erwartet true), gestern % (erwartet false)',
      finance.fn_recurring_chain_ended(v_a, v_t), finance.fn_recurring_chain_ended(v_a, v_t - 1); END IF;

  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_rce_b__', v_acct, -10, 'month', v_t + 30, v_t + 30, NULL) RETURNING id INTO v_b;
  IF finance.fn_recurring_chain_ended(v_b, v_t) THEN RAISE EXCEPTION 'FAIL [3] kuenftiger Start gilt als beendet'; END IF;

  -- [4] Kette: Vorgaenger endet heute, Kopf ist ein leeres Glied [t+100, t+100)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, status)
    VALUES ('__t_rce_c__', v_acct, -10, 'month', v_t - 60, v_t - 60, v_t, 'paused') RETURNING id INTO v_c;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, status, predecessor_id)
    VALUES ('__t_rce_c__', v_acct, -20, 'month', v_t - 60, v_t + 100, v_t + 100, 'paused', v_c) RETURNING id INTO v_d;
  IF NOT finance.fn_recurring_chain_ended(v_d, v_t) OR NOT finance.fn_recurring_chain_ended(v_c, v_t) THEN
    RAISE EXCEPTION 'FAIL [4] beendeter Vorgaenger + leerer kuenftiger Kopf gilt nicht als beendet'; END IF;

  -- [5] Kette: Vorgaenger endete vor 30 Tagen, Kopf laeuft
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_rce_e__', v_acct, -10, 'month', v_t - 90, v_t - 90, v_t - 30) RETURNING id INTO v_e;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, predecessor_id)
    VALUES ('__t_rce_e__', v_acct, -20, 'month', v_t - 90, v_t - 30, NULL, v_e) RETURNING id INTO v_f;
  IF finance.fn_recurring_chain_ended(v_e, v_t) OR finance.fn_recurring_chain_ended(v_f, v_t) THEN
    RAISE EXCEPTION 'FAIL [5] Kette mit laufendem Kopf gilt als beendet'; END IF;

  IF finance.fn_recurring_chain_ended(-1, v_t) THEN RAISE EXCEPTION 'FAIL [6] unbekannte id gilt als beendet'; END IF;
  RAISE NOTICE 'PASS fn_recurring_chain_ended [1-6]';
END $$;

ROLLBACK;
