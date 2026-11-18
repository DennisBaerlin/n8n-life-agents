-- tests/db/finance/test_prop_savings_goal_last_rate_date.sql
-- Eigenschaft: Sparziel mit genannter Monatsrate. Das Zieldatum ist der Tag der LETZTEN Rate:
--   (E1) Zahl der Raten von der ersten Rate bis einschliesslich Zieldatum = ceil(Ziel / Rate);
--   (E2) dasselbe Zieldatum erneut setzen laesst die Rate stehen;
--   (E3) Ziel erhoehen rechnet Rest / Zahl der Raten (Anlegen und Aendern zaehlen gleich): 1.500 bei Rate 100 und
--        12 Raten = 125,00 (nicht 115,39 durch eine 13. Rate am Zieltag).
-- Kombinationen: Ziel/Rate x Abbuchungstag (1, 15, -1) x Laufzeit.
BEGIN;
DO $$
DECLARE
  v_giro INT; v_pot INT; v_res JSONB; v_goal INT; v_rp INT; v_td DATE; v_first DATE; v_cnt INT; v_months INT; v_rate NUMERIC;
  v_r1 NUMERIC; v_new NUMERIC; v_n INT := 0; r RECORD; v_bad TEXT := '';
BEGIN
  SELECT (finance.fn_create_account('{"name":"__lrd_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__lrd_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_pot;
  FOR r IN SELECT * FROM (VALUES (1200, 100, 1), (1000, 300, 15), (1200, 100, -1), (2500, 125, -1), (900, 100, 15), (50000, 200, 1)) x(target, rate, dom) LOOP
    v_n := v_n + 1;
    v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__lrd_goal_'||v_n||'__','goal_type','other','target_amount',r.target,
      'monthly_savings_rate',r.rate,'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',r.dom));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL %: %', r, v_res; END IF;
    v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = v_goal;
    SELECT first_payment_date, abs(amount) INTO v_first, v_rate FROM finance.recurring_payments WHERE id = v_rp;
    v_months := CEIL(r.target::numeric / r.rate)::int;
    SELECT count(*) INTO v_cnt FROM finance.fn_schedule_occurrences(v_first, 1, 'month', r.dom::smallint, NULL, v_first, v_td);
    IF v_cnt <> v_months THEN
      v_bad := v_bad || format(' [E1 Ziel %s Rate %s Tag %s: Zieldatum %s, %s Raten bis dahin statt %s]', r.target, r.rate, r.dom, v_td, v_cnt, v_months);
    END IF;
    PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_date',v_td));
    SELECT abs(amount) INTO v_r1 FROM finance.recurring_payments WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal);
    IF v_r1 <> r.rate THEN v_bad := v_bad || format(' [E2 Ziel %s: Rate %s -> %s nach gleichem Datum]', r.target, r.rate, v_r1); END IF;
  END LOOP;
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__lrd_goal_e3__','goal_type','other','target_amount',1200,
      'monthly_savings_rate',100,'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1));
  v_goal := (v_res->>'goal_id')::int;
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',1500));
  SELECT abs(amount) INTO v_new FROM finance.recurring_payments
   WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal);
  IF v_new IS DISTINCT FROM 125.00 THEN v_bad := v_bad || format(' [E3 Ziel 1200 -> 1500 bei 12 Raten: Rate %s statt 125.00]', v_new); END IF;
  -- (E4) eine einzige Rate reicht (Ziel <= Rate): Zieldatum = Tag der ersten Rate + 1 Tag (muss nach der ersten Rate und in
  --      der Zukunft liegen), bis dahin genau 1 Rate
  FOREACH v_months IN ARRAY ARRAY[1, 15, -1] LOOP
    v_n := v_n + 1;
    v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__lrd_goal_e4_'||v_n||'__','goal_type','other','target_amount',80,
      'monthly_savings_rate',100,'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',v_months));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL E4 Tag %: %', v_months, v_res; END IF;
    v_goal := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = v_goal;
    SELECT first_payment_date INTO v_first FROM finance.recurring_payments WHERE id = v_rp;
    SELECT count(*) INTO v_cnt FROM finance.fn_schedule_occurrences(v_first, 1, 'month', v_months::smallint, NULL, v_first, v_td);
    IF v_td IS DISTINCT FROM v_first + 1 OR v_cnt <> 1 THEN
      v_bad := v_bad || format(' [E4 Tag %s: Zieldatum %s (erwartet %s), %s Raten bis dahin statt 1]', v_months, v_td, v_first + 1, v_cnt);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL Zieldatum = Tag der letzten Rate:%', v_bad; END IF;
  RAISE NOTICE 'PASS Zieldatum = Tag der letzten Rate';
END $$;
ROLLBACK;
