-- tests/db/finance/test_fn_end_recurring_chain.sql
-- finance.fn_end_recurring_chain(rp, end): beendet die laufenden Glieder der eigenen Kette zum Tag end (valid_to
-- exklusiv); ein erst spaeter beginnendes Glied bekommt einen leeren Bereich (valid_to = valid_from); fremde
-- wiederkehrende Zahlungen bleiben unberuehrt. Erfundene Werte, self-contained.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_acc INT; v_old INT; v_head INT; v_other INT; v_n INT;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__t_erc_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_erc_alt__', v_acc, -40, 'month', t - 60, t - 60, t + 20) RETURNING id INTO v_old;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('__t_erc_kopf__', v_acc, -50, 'month', t + 20, t + 20, v_old) RETURNING id INTO v_head;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_erc_fremd__', v_acc, -10, 'month', t - 10, t - 10) RETURNING id INTO v_other;

  v_n := finance.fn_end_recurring_chain(v_head, t + 5);
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [1] zwei Glieder beendet erwartet, got %', v_n; END IF;
  IF (SELECT valid_to FROM finance.recurring_payments WHERE id = v_old) IS DISTINCT FROM t + 5 THEN
    RAISE EXCEPTION 'FAIL [2] laufendes Glied endet am Stichtag'; END IF;
  IF (SELECT valid_to FROM finance.recurring_payments WHERE id = v_head) IS DISTINCT FROM t + 20 THEN
    RAISE EXCEPTION 'FAIL [3] spaeter beginnendes Glied: valid_to = valid_from (leer), got %',
      (SELECT valid_to FROM finance.recurring_payments WHERE id = v_head); END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_other AND status = 'active' AND valid_to IS NULL) THEN
    RAISE EXCEPTION 'FAIL [4] fremde Zahlung veraendert'; END IF;
  RAISE NOTICE 'PASS fn_end_recurring_chain [laufendes Glied, kuenftiges Glied leer, fremde unberuehrt]';
END $$;
ROLLBACK;
