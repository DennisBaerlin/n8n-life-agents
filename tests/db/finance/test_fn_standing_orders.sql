-- tests/db/finance/test_fn_standing_orders.sql
-- finance.fn_standing_orders() — die Dauerauftraege der Bank-To-do: Uebertraege eigenes -> eigenes Konto ('transfer',
-- auch Haushalts-Umbuchungen, auch erst kuenftige) und Spar-Lastschriften ohne Ziel ('debit': Vorsorge, Sparziel-Rate
-- ohne Topf); nie Kredit-Raten, Sparplan-Ausfuehrungen, Eingaenge, sonstige Lastschriften, beendete; je Kette EIN Glied.
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_giro INT; v_pot INT; v_depot INT; v_loan_acc INT;
  r_tr INT; r_future INT; r_goal INT; r_pension INT; r_plan INT; r_loan INT; r_rent INT; r_in INT; r_ended INT; r_c1 INT; r_c2 INT;
  v_got text;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_so_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_so_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__t_so_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_so_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_loan_acc;

  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so transfer', v_giro, v_pot, -100, 'month', t - 30, t - 30) RETURNING id INTO r_tr;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so kuenftig', v_giro, v_pot, -20, 'month', t + 30, t + 30) RETURNING id INTO r_future;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so ziel ohne topf', v_giro, -30, 'month', t + 5, t + 5) RETURNING id INTO r_goal;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id) VALUES ('so ziel', 1000, t + 400, r_goal);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so vorsorge', v_giro, -50, 'month', t + 5, t + 5) RETURNING id INTO r_pension;
  INSERT INTO finance.pension (name, pension_type, recurring_payment_id) VALUES ('so pension', 'private', r_pension);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so sparplan', v_giro, -200, 'month', t + 2, t + 2) RETURNING id INTO r_plan;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id) VALUES ('so plan', v_depot, 'SO1', 'ETF', r_plan);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so kreditrate', v_giro, v_loan_acc, -400, 'month', t + 3, t + 3) RETURNING id INTO r_loan;
  INSERT INTO finance.loans (name, loan_account_id, recurring_payment_id, interest_rate) VALUES ('so kredit', v_loan_acc, r_loan, 3);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so miete', v_giro, -900, 'month', t + 1, t + 1) RETURNING id INTO r_rent;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('so gehalt', v_giro, 3000, 'month', t + 1, t + 1) RETURNING id INTO r_in;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('so beendet', v_giro, v_pot, -10, 'month', t - 90, t - 90, t - 5) RETURNING id INTO r_ended;
  -- Kette: laufendes Glied + kuenftige Aenderung -> nur das laufende Glied
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('so kette alt', v_pot, v_giro, -60, 'month', t - 60, t - 60, t + 60) RETURNING id INTO r_c1;
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('so kette neu', v_pot, v_giro, -80, 'month', t - 60, t + 60, r_c1) RETURNING id INTO r_c2;

  SELECT string_agg(r.name || ':' || so.kind, ',' ORDER BY r.name) INTO v_got
    FROM finance.fn_standing_orders() so JOIN finance.recurring_payments r ON r.id = so.rp_id
   WHERE r.name LIKE 'so %';
  IF v_got IS DISTINCT FROM 'so kette alt:transfer,so kuenftig:transfer,so transfer:transfer,so vorsorge:debit,so ziel ohne topf:debit' THEN
    RAISE EXCEPTION 'FAIL [1] Auswahl/Art, got %', v_got; END IF;
  IF (SELECT so.head_id FROM finance.fn_standing_orders() so WHERE so.rp_id = r_c1) IS DISTINCT FROM r_c2 THEN
    RAISE EXCEPTION 'FAIL [2] head_id = Ketten-Kopf'; END IF;
  RAISE NOTICE 'PASS fn_standing_orders: Uebertraege (auch kuenftig) + Spar-Lastschriften; ohne Kredit/Sparplan/Eingang/Miete/beendet; ein Glied je Kette';
END $$;
ROLLBACK;
