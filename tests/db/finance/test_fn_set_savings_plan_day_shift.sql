-- tests/db/finance/test_fn_set_savings_plan_day_shift.sql
-- Waechter: fn_set_savings_plan aendert den Ausfuehrungstag nur mit einem Rhythmus + Depot-Kalender; der genannte Stichtag ist
-- die erste Ausfuehrung zu den neuen Bedingungen (ein Kalendertag, die Karte zeigt ihn). Liegt sie im selben Monat vor dem
-- alten Tag, behaelt jeder Monat genau eine Ausfuehrung (12 im Jahr); den Wechselpunkt der Zeilen liefert fn_recurring_day_shift.
-- Gegenstueck fuer den spaeteren Tag: test_fn_set_savings_plan_day_shift_later.sql.
BEGIN;

DO $$
DECLARE v_res JSONB; v_rp INT; c1 INT; v_txt TEXT;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__test_spd_settle__","account_type":"cash"}'::jsonb);
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spd_depot__','account_type','stocks_depot',
     'settlement_id',(SELECT id FROM finance.accounts WHERE name = '__test_spd_settle__')));
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__test_spd_plan__','depot_name','__test_spd_depot__',
    'isin','IE00B4L5Y983','symbol','IWDA','security_name','Beispiel','amount',75,'schedule_unit','month',
    'first_payment_date','2031-01-15'));
  v_rp := (v_res->>'recurring_payment_id')::int;
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spd_plan__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','5,20','valid_from','2031-03-05'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL savings_plan day [ok]: %', v_res; END IF;
  SELECT count(*)::int, string_agg(o.due_date::text, ',' ORDER BY o.due_date) FILTER (WHERE o.due_date < '2031-05-01')
    INTO c1, v_txt
  FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-15,2031-02-15,2031-03-05,2031-04-05' THEN
    RAISE EXCEPTION 'FAIL savings_plan day [Anzahl]: % Ausfuehrungen, Reihe % (erwartet 12, ab Maerz am 5.)', c1, v_txt; END IF;
  RAISE NOTICE 'PASS savings_plan day [Kalender-Tag vor dem alten Tag: jeder Monat einmal]';
END $$;

ROLLBACK;
