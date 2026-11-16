-- tests/db/finance/test_prop_savings_goal_rate.sql
-- Eigenschafts-Test: die Sparrate eines Sparziels mit Zieldatum gegen die Termine, die die Vorschau bis zum Zieldatum
-- wirklich zeigt (fn_upcoming_payments), ueber Zielbetrag x Laufzeit x Abbuchungstag.
--   Z1 Rate x Termine bis einschliesslich Zieldatum erreicht das Ziel und liegt hoechstens einen Cent je Termin darueber
--   Z2 Karte = Write: fn_savings_rate_schedule (Vorschau) nennt Rate, Termin-Zahl und ersten Termin wie fn_create_savings_goal
--   Z3 denselben Zielbetrag erneut setzen aendert die Rate nicht
--   Z4 Zielbetrag verdoppeln und zuruecksetzen ergibt wieder die Ausgangs-Rate; dazwischen gilt Z1 fuer den neuen Betrag
-- Grenze: gilt fuer Ziele, die mit target_date angelegt werden; der raten-getriebene Weg (monthly_savings_rate) ist
-- hier bewusst nicht enthalten.
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_prev JSONB; v_giro INT; v_pot INT; v_goal INT; v_rp INT; r RECORD; v_dom INT;
  v_tdate DATE; v_rate NUMERIC; v_rate2 NUMERIC; v_cnt INT; v_n INT := 0;
  v_doms INT[] := ARRAY[NULL,1,15,28,-1,-2];
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_sgr_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__prop_sgr_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_pot;

  FOR r IN SELECT * FROM (VALUES (1000.00, 3), (1000.00, 7), (2500.00, 13), (999.99, 11), (10000.00, 36), (50.00, 2), (777.77, 24)) x(target, months) LOOP
    FOREACH v_dom IN ARRAY v_doms LOOP
      BEGIN
        v_tdate := (v_t + make_interval(months => r.months))::date;
        v_prev := finance.fn_savings_rate_schedule(jsonb_build_object('target_amount',r.target,'target_date',v_tdate)
          || CASE WHEN v_dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', v_dom) END);
        v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__prop_sgr_goal__','goal_type','other','target_amount',r.target,
          'target_date',v_tdate,'account_id',v_giro,'reserve_account_id',v_pot)
          || CASE WHEN v_dom IS NULL THEN '{}'::jsonb ELSE jsonb_build_object('schedule_day_of_month', v_dom) END);
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_prev->>'ok')::boolean IS DISTINCT FROM true THEN
          RAISE EXCEPTION 'FAIL Z setup [ziel=% monate=% tag=%]: % / %', r.target, r.months, v_dom, v_prev, v_res; END IF;
        v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
        SELECT abs(amount) INTO v_rate FROM finance.recurring_payments WHERE id = v_rp;
        SELECT count(*) INTO v_cnt FROM finance.fn_upcoming_payments(v_t, v_tdate) u WHERE u.recurring_payment_id = v_rp;
        -- Z1
        IF v_cnt = 0 OR v_rate * v_cnt < r.target OR v_rate * v_cnt >= r.target + v_cnt * 0.01 THEN
          RAISE EXCEPTION 'FAIL Z1 [ziel=% monate=% tag=%]: Rate % x % Termine = %', r.target, r.months, v_dom, v_rate, v_cnt, v_rate * v_cnt; END IF;
        -- Z2
        IF (v_prev->>'monthly_rate')::numeric IS DISTINCT FROM v_rate OR (v_res->>'monthly_rate')::numeric IS DISTINCT FROM v_rate
           OR (v_prev->>'months')::int IS DISTINCT FROM v_cnt OR (v_res->>'months')::int IS DISTINCT FROM v_cnt
           OR (v_prev->>'first_payment_date')::date IS DISTINCT FROM (SELECT min(u.due_date) FROM finance.fn_upcoming_payments(v_t, v_tdate) u WHERE u.recurring_payment_id = v_rp) THEN
          RAISE EXCEPTION 'FAIL Z2 [ziel=% monate=% tag=%]: Vorschau % Write % gespeichert Rate % Termine %', r.target, r.months, v_dom, v_prev, v_res - 'card_lines', v_rate, v_cnt; END IF;
        -- Z3
        v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',r.target));
        SELECT abs(amount) INTO v_rate2 FROM finance.recurring_payments WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal);
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_rate2 IS DISTINCT FROM v_rate THEN
          RAISE EXCEPTION 'FAIL Z3 [ziel=% monate=% tag=%]: gleiche Eingabe aendert die Rate % -> % (%)', r.target, r.months, v_dom, v_rate, v_rate2, v_res; END IF;
        -- Z4
        v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',r.target * 2));
        SELECT abs(amount) INTO v_rate2 FROM finance.recurring_payments WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal);
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_rate2 * v_cnt < r.target * 2 OR v_rate2 * v_cnt >= r.target * 2 + v_cnt * 0.01
           OR (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM v_rate2 THEN
          RAISE EXCEPTION 'FAIL Z4 [ziel=% monate=% tag=%]: doppeltes Ziel -> Rate % x % Termine (%)', r.target, r.months, v_dom, v_rate2, v_cnt, v_res; END IF;
        IF (SELECT count(*) FROM finance.fn_upcoming_payments(v_t, v_tdate) u
             WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal)))) <> v_cnt THEN
          RAISE EXCEPTION 'FAIL Z4 [ziel=% monate=% tag=%]: Zahl der Termine hat sich mit dem Zielbetrag geaendert', r.target, r.months, v_dom; END IF;
        v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',r.target));
        SELECT abs(amount) INTO v_rate2 FROM finance.recurring_payments WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal);
        IF v_rate2 IS DISTINCT FROM v_rate THEN
          RAISE EXCEPTION 'FAIL Z4 [ziel=% monate=% tag=%]: nach Verdoppeln und Zuruecksetzen Rate % statt %', r.target, r.months, v_dom, v_rate2, v_rate; END IF;
        v_n := v_n + 1;
        RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
      EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
      END;
    END LOOP;
  END LOOP;
  RAISE NOTICE 'PASS prop savings goal rate [% Kombinationen Zielbetrag x Laufzeit x Abbuchungstag, Z1-Z4]', v_n;
END $$;

ROLLBACK;
