-- tests/db/finance/test_fn_recurring_is_single.sql
-- Einmalige erwartete Zahlung = Zeile mit Jahres-Rhythmus, deren Gueltigkeit direkt nach dem ersten Termin endet.
-- finance.fn_recurring_is_single ist die eine Adresse fuer "genau ein Termin". Eine solche Zahlung zaehlt nicht in die
-- Monatsrechnung (recurring_cashflow_classified, monthly_cashflow_summary) und nicht in fn_account_flows, bleibt aber am
-- Termin faellig (fn_recurring_due_open) und sichtbar (upcoming_recurring_payments). Gegenprobe: dieselbe Jahres-Zahlung
-- ohne Ende zaehlt mit einem Zwoelftel; ein Glied einer Kette (Vorgaenger) ist nie "einmalig".
BEGIN;

DO $$
DECLARE
  v_giro int; v_once int; v_year int; v_d date := current_date + 20;
  v_before numeric; v_after numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_once_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  SELECT COALESCE(monthly_consumption, 0) INTO v_before FROM finance.monthly_cashflow_summary;

  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, valid_to, status)
    VALUES ('__t_once__', v_giro, -1200, 1, 'year', v_d, v_d, v_d + 1, 'active') RETURNING id INTO v_once;

  IF finance.fn_recurring_is_single(v_once) IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1 einmalig erkannt]'; END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_cashflow_classified WHERE id = v_once) THEN
    RAISE EXCEPTION 'FAIL [2 Einzelzahlung in der Klassen-View]'; END IF;
  SELECT COALESCE(monthly_consumption, 0) INTO v_after FROM finance.monthly_cashflow_summary;
  IF v_after IS DISTINCT FROM v_before THEN
    RAISE EXCEPTION 'FAIL [2 Monatsrechnung zaehlt die Einzelzahlung: % -> %]', v_before, v_after; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_account_flows(v_giro) f WHERE f.rp_id = v_once) THEN
    RAISE EXCEPTION 'FAIL [3 Einzelzahlung in fn_account_flows]'; END IF;
  IF (SELECT count(*) FROM finance.fn_recurring_due_open(current_date, current_date + 400) d WHERE d.recurring_payment_id = v_once) <> 1
     OR NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_d, v_d) d WHERE d.recurring_payment_id = v_once) THEN
    RAISE EXCEPTION 'FAIL [4 Einzelzahlung nicht genau einmal am Termin faellig]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.upcoming_recurring_payments WHERE id = v_once) THEN
    RAISE EXCEPTION 'FAIL [5 Einzelzahlung nicht mehr sichtbar]'; END IF;

  -- Gegenprobe: Jahres-Zahlung ohne Ende zaehlt (ein Zwoelftel), ist nicht einmalig
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__t_yearly__', v_giro, -1200, 1, 'year', v_d, v_d, 'active') RETURNING id INTO v_year;
  IF finance.fn_recurring_is_single(v_year) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6 Jahres-Zahlung als einmalig]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_cashflow_classified WHERE id = v_year AND consumption_eur = -100) THEN
    RAISE EXCEPTION 'FAIL [6 Jahres-Zahlung zaehlt nicht mit -100]'; END IF;

  -- Ein Glied einer Kette (hier: Nachfolger mit einem Termin) ist keine Einzelzahlung
  UPDATE finance.recurring_payments SET predecessor_id = v_year WHERE id = v_once;
  IF finance.fn_recurring_is_single(v_once) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 Ketten-Glied als einmalig]'; END IF;
  IF finance.fn_recurring_is_single(-1) IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 unbekannte id]'; END IF;

  RAISE NOTICE 'PASS fn_recurring_is_single [Einzelzahlung ausser Monatsrechnung, am Termin faellig, Gegenproben]';
END $$;

ROLLBACK;
