-- tests/db/finance/test_fn_app_order_line.sql
-- finance.fn_app_order_line(rp) — „Betrag · Rhythmus[ · ab Datum]" eines Dauerauftrags fuer die Bank-To-do der Mini-App:
-- monatlich am Tag / an festen Tagen / Monatsende / vorletzter Tag / Tag frei (gerechnet); sonst Haeufigkeit +
-- naechster Termin; „ab" nur fuer ein erst kuenftig startendes Glied; Betrag in Waehrung des Quellkontos.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_eur INT; v_usd INT; v_rp INT; v jsonb;
BEGIN
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ol2_eur__', 'cash', 'EUR', 'active') RETURNING id INTO v_eur;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_ol2_usd__', 'cash', 'USD', 'active') RETURNING id INTO v_usd;

  -- monatlich am 15., laeuft schon -> ohne „ab"
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('ol day', v_eur, -150, 'month', 15, t - 60, t - 60) RETURNING id INTO v_rp;
  IF finance.fn_app_order_line(v_rp) <> core.fn_ui_tpl('finance.app.goals.amount_rhythm', jsonb_build_object(
       'amount', core.fn_ui_money(150, 'EUR'),
       'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_day', jsonb_build_object('day', core.fn_ui_num(15))))) THEN
    RAISE EXCEPTION 'FAIL [1] monatlich am 15., got %', finance.fn_app_order_line(v_rp); END IF;
  -- erst kuenftig, ohne festen Tag, USD-Quelle -> „ab" + Tag frei (Tag des ersten Termins) + USD
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('ol free', v_usd, -40, 'month', t + 10, t + 10) RETURNING id INTO v_rp;
  IF finance.fn_app_order_line(v_rp) <> core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
       'amount', core.fn_ui_money(40, 'USD'),
       'rhythm', core.fn_ui_tpl('finance.app.goals.rhythm_month_free', jsonb_build_object('day', core.fn_ui_num(extract(day FROM t + 10)))),
       'date', core.fn_ui_date(t + 10))) THEN
    RAISE EXCEPTION 'FAIL [2] ab + Tag frei + USD, got %', finance.fn_app_order_line(v_rp); END IF;
  -- Monatsende / vorletzter Tag / feste Tage
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('ol -1', v_eur, -10, 'month', -1, t - 60, t - 60) RETURNING id INTO v_rp;
  IF finance.fn_app_order_line(v_rp)->'params'->'rhythm' <> core.fn_ui_tpl('finance.app.goals.rhythm_month_end') THEN RAISE EXCEPTION 'FAIL [3] -1'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_day_of_month, first_payment_date, valid_from)
    VALUES ('ol -2', v_eur, -10, 'month', -2, t - 60, t - 60) RETURNING id INTO v_rp;
  IF finance.fn_app_order_line(v_rp)->'params'->'rhythm' <> core.fn_ui_tpl('finance.app.goals.rhythm_month_second_last') THEN RAISE EXCEPTION 'FAIL [4] -2'; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
    VALUES ('ol days', v_eur, -10, 'month', '{2,16}', t - 60, t - 60) RETURNING id INTO v_rp;
  IF finance.fn_app_order_line(v_rp)->'params'->'rhythm' <> core.fn_ui_tpl('finance.app.goals.rhythm_month_days', '{"days":"2, 16"}') THEN
    RAISE EXCEPTION 'FAIL [5] feste Tage, got %', finance.fn_app_order_line(v_rp); END IF;
  -- vierteljaehrlich / jaehrlich: Haeufigkeit + naechster Termin
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_interval, first_payment_date, valid_from)
    VALUES ('ol q', v_eur, -90, 'month', 3, t + 5, t + 5) RETURNING id INTO v_rp;
  v := finance.fn_app_order_line(v_rp)->'params'->'rhythm';
  IF v <> core.fn_ui_tpl('finance.app.goals.rhythm_quarterly', jsonb_build_object('date', core.fn_ui_date(t + 5))) THEN
    RAISE EXCEPTION 'FAIL [6] vierteljaehrlich, got %', v; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('ol y', v_eur, -300, 'year', t + 20, t - 400) RETURNING id INTO v_rp;
  v := finance.fn_app_order_line(v_rp)->'params'->'rhythm';
  IF v <> core.fn_ui_tpl('finance.app.goals.rhythm_yearly', jsonb_build_object('date', core.fn_ui_date(t + 20))) THEN
    RAISE EXCEPTION 'FAIL [7] jaehrlich, got %', v; END IF;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_interval, first_payment_date, valid_from)
    VALUES ('ol 2w', v_eur, -5, 'week', 2, t + 3, t + 3) RETURNING id INTO v_rp;
  v := finance.fn_app_order_line(v_rp)->'params'->'rhythm';
  IF v <> core.fn_ui_tpl('finance.app.goals.rhythm_weeks', jsonb_build_object('n', core.fn_ui_num(2), 'date', core.fn_ui_date(t + 3))) THEN
    RAISE EXCEPTION 'FAIL [8] alle 2 Wochen, got %', v; END IF;
  IF finance.fn_app_order_line(-1) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [9] unbekannt -> NULL'; END IF;
  RAISE NOTICE 'PASS fn_app_order_line: Tag, ab + Tag frei, Monatsende, vorletzter Tag, feste Tage, Haeufigkeiten';
END $$;
ROLLBACK;
