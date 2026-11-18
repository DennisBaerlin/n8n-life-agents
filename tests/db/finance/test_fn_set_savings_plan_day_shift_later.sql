-- tests/db/finance/test_fn_set_savings_plan_day_shift_later.sql
-- Eigenschaft: Sparplan, Ausfuehrungstag auf einen SPAETEREN Tag im selben Monat verlegt (Ausfuehrungstag 15., Stichtag 20.03.):
-- der Uebergangsmonat hat genau EINE Ausfuehrung, und zwar am genannten Tag (20.03.); die am 15.03. entfaellt.
-- Jeder Monat behaelt eine Ausfuehrung (12 im Jahr). Gegenstueck fuer den frueheren Tag:
-- test_fn_set_savings_plan_day_shift.sql.
BEGIN;
DO $$
DECLARE v_res JSONB; v_rp INT; c1 INT; v_txt TEXT;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__test_spl_settle__","account_type":"cash"}'::jsonb);
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spl_depot__','account_type','stocks_depot',
     'settlement_id',(SELECT id FROM finance.accounts WHERE name = '__test_spl_settle__')));
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__test_spl_plan__','depot_name','__test_spl_depot__',
    'isin','IE00B4L5Y983','symbol','IWDA','security_name','Beispiel','amount',75,'schedule_unit','month',
    'first_payment_date','2031-01-15'));
  v_rp := (v_res->>'recurring_payment_id')::int;
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spl_plan__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','20','valid_from','2031-03-20'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL savings_plan later day [ok]: %', v_res; END IF;
  SELECT count(*)::int, string_agg(o.due_date::text, ',' ORDER BY o.due_date) FILTER (WHERE o.due_date < '2031-05-01')
    INTO c1, v_txt
  FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
  IF c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-15,2031-02-15,2031-03-20,2031-04-20' THEN
    RAISE EXCEPTION 'FAIL savings_plan later day [Anzahl]: % Ausfuehrungen, Reihe % (erwartet 12, im Maerz nur am 20.)', c1, v_txt; END IF;
  RAISE NOTICE 'PASS savings_plan later day [Uebergangsmonat: eine Ausfuehrung am genannten Tag]';
END $$;
ROLLBACK;

-- Weitere Lagen derselben Eigenschaft (jeder Monat genau eine Ausfuehrung):
--  (E) Plan mit Ende 01.07.: das Ende wandert mit, die letzte Ausfuehrung ist am 20.06. (nicht am 15.06., keine 7.)
--  (B) alte Ausfuehrung des Uebergangsmonats schon uebersprungen -> {ok:false, code:'day_shift_booked', first_free_date}
--      ohne Write (Plan unveraendert), danach mit Stichtag im Folgemonat ok
--  (F) Plan beginnt im selben Monat (Verlegung im Anlagemonat) -> ebenfalls day_shift_booked statt zwei Ausfuehrungen
BEGIN;
DO $$
DECLARE v_res JSONB; v_rp INT; v_txt TEXT; v_head INT; v_wr INT;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__test_spl2_settle__","account_type":"cash"}'::jsonb);
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spl2_depot__','account_type','stocks_depot',
     'settlement_id',(SELECT id FROM finance.accounts WHERE name = '__test_spl2_settle__')));
  -- (E)
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__test_spl2_end__','depot_name','__test_spl2_depot__',
    'isin','IE00B4L5Y983','symbol','IWDA','security_name','Beispiel','amount',75,'schedule_unit','month',
    'first_payment_date','2031-01-15'));
  v_rp := (v_res->>'recurring_payment_id')::int;
  UPDATE finance.recurring_payments SET valid_to = DATE '2031-07-01' WHERE id = v_rp;   -- Ende des Plans (Zeit-Vorgabe, kein Write-Weg im Test)
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spl2_end__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','20','valid_from','2031-03-20'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL later day [E ok]: %', v_res; END IF;
  SELECT string_agg(o.due_date::text, ',' ORDER BY o.due_date) INTO v_txt
  FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((v_res->>'recurring_payment_id')::int));
  IF v_txt IS DISTINCT FROM '2031-01-15,2031-02-15,2031-03-20,2031-04-20,2031-05-20,2031-06-20' THEN
    RAISE EXCEPTION 'FAIL later day [E Ende]: Reihe % (erwartet Jan/Feb am 15., Maerz bis Juni am 20., dann Schluss)', v_txt; END IF;
  -- (B) eigenes Depot: die Verlegung in (E) hat den Depot-Kalender auf den 20. gestellt
  PERFORM finance.fn_create_account('{"name":"__test_spl2_settle_b__","account_type":"cash"}'::jsonb);
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spl2_depot_b__','account_type','stocks_depot',
     'settlement_id',(SELECT id FROM finance.accounts WHERE name = '__test_spl2_settle_b__')));
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__test_spl2_booked__','depot_name','__test_spl2_depot_b__',
    'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel B','amount',40,'schedule_unit','month',
    'first_payment_date','2031-01-15'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL later day [B Anlage]: %', v_res; END IF;
  v_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', '2031-03-15'));
  SELECT count(*) INTO v_wr FROM finance.recurring_payments;
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spl2_booked__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','20','valid_from','2031-03-20'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'code' IS DISTINCT FROM 'day_shift_booked'
     OR (v_res->>'first_free_date')::date IS DISTINCT FROM DATE '2031-04-20'
     OR (SELECT count(*) FROM finance.recurring_payments) <> v_wr THEN
    RAISE EXCEPTION 'FAIL later day [B gebucht]: % (erwartet day_shift_booked, erster freier Tag 2031-04-20, kein Write)', v_res; END IF;
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spl2_booked__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','20','valid_from','2031-04-20'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL later day [B Folgemonat ok]: %', v_res; END IF;
  SELECT string_agg(o.due_date::text, ',' ORDER BY o.due_date) INTO v_txt
  FROM finance.fn_recurring_due_open('2031-01-01', '2031-06-30') o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((v_res->>'recurring_payment_id')::int));
  IF v_txt IS DISTINCT FROM '2031-01-15,2031-02-15,2031-04-20,2031-05-20,2031-06-20' THEN
    RAISE EXCEPTION 'FAIL later day [B Folgemonat]: Reihe % (15.03. uebersprungen, ab April am 20.)', v_txt; END IF;
  -- (F) wieder ein eigenes Depot (Kalender nach (B) auf dem 20.)
  PERFORM finance.fn_create_account('{"name":"__test_spl2_settle_c__","account_type":"cash"}'::jsonb);
  PERFORM finance.fn_create_account(jsonb_build_object('name','__test_spl2_depot_c__','account_type','stocks_depot',
     'settlement_id',(SELECT id FROM finance.accounts WHERE name = '__test_spl2_settle_c__')));
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__test_spl2_first__','depot_name','__test_spl2_depot_c__',
    'isin','IE00B3RBWM25','symbol','VWRL','security_name','Beispiel C','amount',25,'schedule_unit','month',
    'first_payment_date','2032-01-15'));
  v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__test_spl2_first__','schedule_unit','month',
    'schedule_interval',1,'depot_execution_days','20','valid_from','2032-01-20'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'code' IS DISTINCT FROM 'day_shift_booked'
     OR (v_res->>'first_free_date')::date IS DISTINCT FROM DATE '2032-02-20' THEN
    RAISE EXCEPTION 'FAIL later day [F Anlagemonat]: % (erwartet day_shift_booked, erster freier Tag 2032-02-20)', v_res; END IF;
  RAISE NOTICE 'PASS savings_plan later day [Ende wandert mit; gebucht/Anlagemonat -> day_shift_booked ohne Write; Folgemonat ok]';
END $$;
ROLLBACK;
