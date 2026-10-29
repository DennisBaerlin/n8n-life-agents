-- tests/db/finance/test_fn_recurring_effective.sql
-- finance.fn_recurring_effective(rp, on) — massgebliches Glied einer Raten-Kette: heute gueltig; sonst das NAECHSTE
-- startende Glied (auch bei einer Luecke zwischen zwei Gliedern), nicht der Kopf; beendete Kette -> Kopf.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_acc INT; v_1 INT; v_2 INT; v_3 INT; v_x INT;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_re_a__', 'cash', 'EUR', 'active') RETURNING id INTO v_acc;
  -- Glied 1 endete letzten Monat, Glied 2 startet in 30 Tagen (100), Kopf 3 in 180 Tagen (150)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('re 1', v_acc, -80, 'month', t - 200, t - 200, t - 20) RETURNING id INTO v_1;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, predecessor_id)
    VALUES ('re 2', v_acc, -100, 'month', t - 200, t + 30, t + 180, v_1) RETURNING id INTO v_2;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('re 3', v_acc, -150, 'month', t - 200, t + 180, v_2) RETURNING id INTO v_3;

  IF finance.fn_recurring_effective(v_3, t) IS DISTINCT FROM v_2 THEN
    RAISE EXCEPTION 'FAIL [1] Luecke heute -> naechstes Glied 2, got %', finance.fn_recurring_effective(v_3, t); END IF;
  IF finance.fn_recurring_effective(v_1, t - 100) IS DISTINCT FROM v_1 THEN RAISE EXCEPTION 'FAIL [2] gueltiges Glied'; END IF;
  IF finance.fn_recurring_effective(v_2, t + 200) IS DISTINCT FROM v_3 THEN RAISE EXCEPTION 'FAIL [3] Kopf gueltig'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('re beendet', v_acc, -10, 'month', t - 90, t - 90, t - 5) RETURNING id INTO v_x;
  IF finance.fn_recurring_effective(v_x, t) IS DISTINCT FROM v_x THEN RAISE EXCEPTION 'FAIL [4] beendete Kette -> Kopf'; END IF;
  IF finance.fn_recurring_effective(-1, t) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5] unbekannt -> NULL'; END IF;
  RAISE NOTICE 'PASS fn_recurring_effective: gueltig, Luecke -> naechstes Glied, Kopf, beendet, unbekannt';
END $$;
ROLLBACK;
