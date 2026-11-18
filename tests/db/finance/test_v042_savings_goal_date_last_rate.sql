-- tests/db/finance/test_v042_savings_goal_date_last_rate.sql
-- finance:V042 (echte Datei, zweimal): ein Altbestands-Sparziel mit Rate (Zieldatum einen Monat NACH der letzten Rate)
-- bekommt einmalig das Datum der letzten Rate; Folge: Ziel erhoehen rechnet Rest / Zahl der Raten (125,00 statt 115,39).
--   (a) Altbestand: Ziel 1.200, Rate 100 (12 Raten), Datum auf die alte Lesart (13. Rasterpunkt) gestellt -> nach V042 der
--       12. Rasterpunkt; ein zweiter Lauf aendert nichts; Ziel auf 1.500 erhoehen -> Rate 125,00
--   (b) genanntes Datum (Rate rechnet aus den Terminen bis einschliesslich Zieldatum) bleibt unberuehrt
--   (c) Ziel mit Startbestand: Rest = Ziel - Startbestand (Ziel 1.200, Startbestand 200, Rate 100 -> 10 Raten, Datum 11. Punkt -> 10.)
--   (d) eine einzige Rate reicht (Ziel 80, Rate 100): Datum = erste Rate + 1, schon richtig, bleibt
-- hand-injected: der Altbestand entsteht durch Zuruecksetzen von savings_goals.target_date auf die alte Lesart (die
--   Write-fns rechnen nur noch die neue); alles andere entsteht ueber die echten Write-fns.
BEGIN;

DO $$
DECLARE
  v_giro INT; v_pot INT; v_res JSONB; v_a INT; v_b INT; v_c INT; v_d INT; v_first DATE;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__v42_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__v42_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_pot;
  v_first := current_date + 20;
  -- (a)
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__v42_a__','goal_type','other','target_amount',1200,'monthly_savings_rate',100,
    'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL a: %', v_res; END IF;
  v_a := (v_res->>'goal_id')::int;
  UPDATE finance.savings_goals SET target_date = (v_first + interval '12 months')::date WHERE id = v_a;
  -- (b) genanntes Datum: Termin am Zieltag zaehlt mit (13 Termine), Rate 92,31
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__v42_b__','goal_type','other','target_amount',1200,
    'target_date',(v_first + interval '12 months')::date,'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL b: %', v_res; END IF;
  v_b := (v_res->>'goal_id')::int;
  -- (c) Startbestand 200
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_pot,'amount',500,'direction','inflow','transaction_date',current_date - 5,'description','Start'));
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__v42_c__','goal_type','other','target_amount',1200,'monthly_savings_rate',100,
    'already_saved',200,'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL c: %', v_res; END IF;
  v_c := (v_res->>'goal_id')::int;
  UPDATE finance.savings_goals SET target_date = (v_first + interval '10 months')::date WHERE id = v_c;
  -- (d)
  v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__v42_d__','goal_type','other','target_amount',80,'monthly_savings_rate',100,
    'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',v_first));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL d: %', v_res; END IF;
  v_d := (v_res->>'goal_id')::int;
  CREATE TEMP TABLE _v42 AS SELECT v_a AS a, v_b AS b, v_c AS c, v_d AS d, v_first AS first;
END $$;

CREATE TEMP TABLE _v42_before AS SELECT id, target_date FROM finance.savings_goals WHERE name LIKE '\_\_v42\_%';

\ir ../../../packages/finance/db/migrations/V042__savings_goal_date_last_rate.sql
\ir ../../../packages/finance/db/migrations/V042__savings_goal_date_last_rate.sql

DO $$
DECLARE
  x RECORD; v_td DATE; v_res JSONB; v_rate NUMERIC;
BEGIN
  SELECT * INTO x FROM _v42;
  SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = x.a;
  IF v_td IS DISTINCT FROM (x.first + interval '11 months')::date THEN
    RAISE EXCEPTION 'FAIL V042 [a]: Zieldatum % (erwartet % = 12. Rate)', v_td, (x.first + interval '11 months')::date; END IF;
  SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = x.b;
  IF v_td IS DISTINCT FROM (SELECT target_date FROM _v42_before WHERE id = x.b) THEN
    RAISE EXCEPTION 'FAIL V042 [b]: genanntes Datum veraendert: %', v_td; END IF;
  SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = x.c;
  IF v_td IS DISTINCT FROM (x.first + interval '9 months')::date THEN
    RAISE EXCEPTION 'FAIL V042 [c]: Zieldatum % (erwartet % = 10. Rate)', v_td, (x.first + interval '9 months')::date; END IF;
  SELECT target_date INTO v_td FROM finance.savings_goals WHERE id = x.d;
  IF v_td IS DISTINCT FROM (SELECT target_date FROM _v42_before WHERE id = x.d) THEN
    RAISE EXCEPTION 'FAIL V042 [d]: n=1-Ziel veraendert: %', v_td; END IF;
  -- Folge: Ziel erhoehen -> Rest / 12 Raten
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', x.a, 'target_amount', 1500));
  SELECT abs(amount) INTO v_rate FROM finance.recurring_payments WHERE id = (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = x.a);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_rate IS DISTINCT FROM 125.00 THEN
    RAISE EXCEPTION 'FAIL V042 [a Erhoehung]: Rate % statt 125.00 (%)', v_rate, v_res - 'card_lines'; END IF;
  RAISE NOTICE 'PASS V042 [Altbestand auf den Tag der letzten Rate, genanntes Datum/Startbestand/n=1 richtig, zweimal gelaufen]';
END $$;

ROLLBACK;
