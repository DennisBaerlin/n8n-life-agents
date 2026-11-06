-- tests/db/finance/test_fn_recurring_last_valid_day.sql
-- Der letzte gueltige Tag einer Raten-Kette, aus der DB gelesen statt aus valid_to abgeleitet (Eigenschaft aus dem Live-Test:
-- das halboffene valid_to wurde als letzter Termin gelesen und einen Tag zu spaet genannt).
--   1) fn_recurring_last_valid_day: offen NULL, Ende D, geerbtes Ende nach Split, nur geplante Aenderung NULL, leerer Kopf
--   2) standing_order_overview: last_valid_day + last_execution vom Kopf der Kette, kein valid_to; Ende ausserhalb des Rasters
--   3) active_recurring_payments, monthly_cashflow_overview: Eingabe D -> D, geplante Aenderung ist kein Ende
--   4) upcoming_recurring_payments: Eingabe D -> D
--   5) active_insurances: Eingabe D -> D, auch mit leerem Kopf; valid_to bleibt (gespeichertes Monitor-SQL)
--   6) fn_advisor_snapshot: jede Liste traegt D, kein Schluessel valid_to
-- Self-contained (BEGIN..ROLLBACK), Werte erfunden.
BEGIN;
DO $$
DECLARE
  t       DATE := CURRENT_DATE;
  v_m1    DATE := (date_trunc('month', CURRENT_DATE) + interval '1 month')::date;
  v_m2    DATE := (date_trunc('month', CURRENT_DATE) + interval '2 month')::date;
  v_end   DATE := CURRENT_DATE + 100;
  v_giro  INT; v_pot INT;
  v_a INT; v_b INT; v_rp INT; v_ins INT;
  v_res   JSONB; v JSONB; r RECORD;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_lvd_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__t_lvd_pot__', 'cash', 'EUR', 'active') RETURNING id INTO v_pot;

  -- ===== 1) Die Funktion =====
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__t_lvd_offen__', v_giro, -10, 'month', t - 10, t - 10) RETURNING id INTO v_a;
  IF finance.fn_recurring_last_valid_day(v_a) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1a offen]: %', finance.fn_recurring_last_valid_day(v_a); END IF;

  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_lvd_ende__', v_giro, -10, 'month', t - 10, t - 10, v_end + 1) RETURNING id INTO v_a;
  IF finance.fn_recurring_last_valid_day(v_a) IS DISTINCT FROM v_end THEN RAISE EXCEPTION 'FAIL [1b Ende]: %', finance.fn_recurring_last_valid_day(v_a); END IF;

  -- geerbtes Ende: altes Glied endet am Wechsel, der Kopf traegt das echte Ende; jedes Glied liefert dasselbe
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_lvd_kette__', v_giro, -10, 'month', t - 10, t - 10, t + 20) RETURNING id INTO v_a;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, predecessor_id)
    VALUES ('__t_lvd_kette__', v_giro, -12, 'month', t - 10, t + 20, v_end + 1, v_a) RETURNING id INTO v_b;
  IF finance.fn_recurring_last_valid_day(v_a) IS DISTINCT FROM v_end OR finance.fn_recurring_last_valid_day(v_b) IS DISTINCT FROM v_end THEN
    RAISE EXCEPTION 'FAIL [1c geerbtes Ende]: % / %', finance.fn_recurring_last_valid_day(v_a), finance.fn_recurring_last_valid_day(v_b); END IF;

  -- nur geplante Aenderung: die Kette laeuft weiter, der Tag vor dem Wechsel ist kein Ende
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_lvd_wechsel__', v_giro, -10, 'month', t - 10, t - 10, t + 20) RETURNING id INTO v_a;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, predecessor_id)
    VALUES ('__t_lvd_wechsel__', v_giro, -12, 'month', t - 10, t + 20, v_a);
  IF finance.fn_recurring_last_valid_day(v_a) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1d Wechsel ist kein Ende]: %', finance.fn_recurring_last_valid_day(v_a); END IF;

  -- leerer Kopf [x,x): das Ende steht am letzten nicht leeren Glied
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_lvd_leer__', v_giro, -10, 'month', t - 10, t - 10, v_end + 1) RETURNING id INTO v_a;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to, predecessor_id)
    VALUES ('__t_lvd_leer__', v_giro, -12, 'month', t - 10, v_end + 30, v_end + 30, v_a) RETURNING id INTO v_b;
  IF finance.fn_recurring_last_valid_day(v_b) IS DISTINCT FROM v_end THEN RAISE EXCEPTION 'FAIL [1e leerer Kopf]: %', finance.fn_recurring_last_valid_day(v_b); END IF;
  -- die Namens-Aufloesung zeigt denselben Tag wie die Views (Kandidaten sind Koepfe)
  IF ((SELECT candidates FROM finance.fn_resolve_recurring_payment('__t_lvd_leer__'))->0->>'last_valid_day')::date IS DISTINCT FROM v_end THEN
    RAISE EXCEPTION 'FAIL [1f Kandidat]: %', (SELECT candidates FROM finance.fn_resolve_recurring_payment('__t_lvd_leer__')); END IF;

  -- nur leere Glieder: nie „kein Ende“, sonst hielte der Berater einen endenden Vertrag fuer unbefristet
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, valid_to)
    VALUES ('__t_lvd_nur_leer__', v_giro, -10, 'month', t + 30, t + 30, t + 30) RETURNING id INTO v_a;
  IF finance.fn_recurring_last_valid_day(v_a) IS DISTINCT FROM t + 29 THEN RAISE EXCEPTION 'FAIL [1g nur leere Glieder]: %', finance.fn_recurring_last_valid_day(v_a); END IF;
  DELETE FROM finance.recurring_payments WHERE name LIKE '\_\_t\_lvd\_%' AND predecessor_id IS NOT NULL;
  DELETE FROM finance.recurring_payments WHERE name LIKE '\_\_t\_lvd\_%';
  RAISE NOTICE 'PASS [1 fn_recurring_last_valid_day: offen, Ende, geerbt, Wechsel, leerer Kopf]';

  -- ===== 2) Dauerauftraege =====
  -- Ende ausserhalb des Rasters: letzter Termin am Ersten, genanntes Ende fuenf Tage spaeter
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__t_lvd_so_raster__', 'from_account_id', v_giro, 'to_account_id', v_pot, 'amount', 50,
    'schedule_unit', 'month', 'schedule_day_of_month', 1, 'first_payment_date', v_m1::text, 'valid_to', (v_m2 + 5)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [2 Raster]: %', v_res; END IF;
  SELECT * INTO r FROM (SELECT to_jsonb(s) AS j FROM finance.standing_order_overview s WHERE s.name = '__t_lvd_so_raster__') x;
  IF (r.j->>'last_valid_day')::date IS DISTINCT FROM v_m2 + 5 OR (r.j->>'last_execution')::date IS DISTINCT FROM v_m2 THEN
    RAISE EXCEPTION 'FAIL [2a Ende/Termin]: %', r.j; END IF;
  IF r.j ? 'valid_to' THEN RAISE EXCEPTION 'FAIL [2b valid_to in der View]: %', r.j; END IF;

  -- offen + nur geplante Betragsaenderung: beide leer
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__t_lvd_so_offen__', 'from_account_id', v_giro, 'to_account_id', v_pot, 'amount', 60,
    'schedule_unit', 'month', 'first_payment_date', (t - 10)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [2 offen]: %', v_res; END IF;
  v_rp := (v_res->>'recurring_payment_id')::int;
  v_res := finance.fn_split_recurring_payment(v_rp, t + 45, -70, NULL, NULL, NULL, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [2 Split]: %', v_res; END IF;
  SELECT * INTO r FROM (SELECT to_jsonb(s) AS j FROM finance.standing_order_overview s WHERE s.name = '__t_lvd_so_offen__') x;
  IF r.j IS NULL OR r.j->>'last_valid_day' IS NOT NULL OR r.j->>'last_execution' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2c geplante Aenderung ist kein Ende]: %', r.j; END IF;

  -- Ende D, danach geplante Aenderung: der Kopf erbt D, die View zeigt D, nicht den Tag vor dem Wechsel
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__t_lvd_so_beides__', 'from_account_id', v_giro, 'to_account_id', v_pot, 'amount', 80,
    'schedule_unit', 'month', 'first_payment_date', (t - 10)::text, 'valid_to', v_end::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [2 beides]: %', v_res; END IF;
  v_res := finance.fn_split_recurring_payment((v_res->>'recurring_payment_id')::int, t + 45, -90, NULL, NULL, NULL, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [2 beides Split]: %', v_res; END IF;
  SELECT * INTO r FROM (SELECT to_jsonb(s) AS j FROM finance.standing_order_overview s WHERE s.name = '__t_lvd_so_beides__') x;
  IF (r.j->>'last_valid_day')::date IS DISTINCT FROM v_end THEN RAISE EXCEPTION 'FAIL [2d Ende der Kette]: %', r.j; END IF;
  RAISE NOTICE 'PASS [2 standing_order_overview: Ende und letzter Termin vom Kopf, kein valid_to]';

  -- ===== 3) Laufende Zahlung =====
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name', '__t_lvd_abo__', 'account_id', v_giro, 'direction', 'expense', 'amount', 15,
    'schedule_unit', 'month', 'first_payment_date', (t - 5)::text, 'valid_to', v_end::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [3 Abo]: %', v_res; END IF;
  IF (SELECT last_valid_day FROM finance.active_recurring_payments WHERE name = '__t_lvd_abo__') IS DISTINCT FROM v_end
     OR (SELECT last_valid_day FROM finance.monthly_cashflow_overview WHERE name = '__t_lvd_abo__') IS DISTINCT FROM v_end THEN
    RAISE EXCEPTION 'FAIL [3a Eingabe D -> D]'; END IF;

  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name', '__t_lvd_miete__', 'account_id', v_giro, 'direction', 'expense', 'amount', 25,
    'schedule_unit', 'month', 'first_payment_date', (t - 5)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [3 offen]: %', v_res; END IF;
  v_res := finance.fn_split_recurring_payment((v_res->>'recurring_payment_id')::int, t + 45, -30, NULL, NULL, NULL, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [3 Split]: %', v_res; END IF;
  IF (SELECT last_valid_day FROM finance.active_recurring_payments WHERE name = '__t_lvd_miete__' AND valid_from <= t) IS NOT NULL
     OR (SELECT last_valid_day FROM finance.monthly_cashflow_overview WHERE name = '__t_lvd_miete__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3b geplante Aenderung ist kein Ende]'; END IF;
  RAISE NOTICE 'PASS [3 active_recurring_payments, monthly_cashflow_overview: Ende der Kette]';

  -- ===== 4) Erst kommend (Start ausserhalb eines Rhythmus -> planned_recurring im Snapshot) =====
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name', '__t_lvd_spaeter__', 'account_id', v_giro, 'direction', 'expense', 'amount', 35,
    'schedule_unit', 'month', 'first_payment_date', (t + 60)::text, 'valid_to', (t + 200)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [4 spaeter]: %', v_res; END IF;
  IF (SELECT last_valid_day FROM finance.upcoming_recurring_payments WHERE name = '__t_lvd_spaeter__') IS DISTINCT FROM t + 200 THEN
    RAISE EXCEPTION 'FAIL [4 upcoming]'; END IF;
  RAISE NOTICE 'PASS [4 upcoming_recurring_payments: Eingabe D -> D]';

  -- ===== 5) Versicherung =====
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name', '__t_lvd_police__', 'insurance_company', 'Beispiel AG', 'premium_amount', '20', 'schedule_unit', 'month',
    'debit_account_id', v_giro, 'first_payment_date', (t - 5)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [5 Police]: %', v_res; END IF;
  v_ins := (v_res->>'insurance_id')::int;
  v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id', v_ins, 'valid_to', v_end::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [5 Ende]: %', v_res; END IF;
  SELECT * INTO r FROM (SELECT to_jsonb(s) AS j FROM finance.active_insurances s WHERE s.id = v_ins) x;
  IF (r.j->>'last_valid_day')::date IS DISTINCT FROM v_end OR (r.j->>'valid_to')::date IS DISTINCT FROM v_end + 1 THEN
    RAISE EXCEPTION 'FAIL [5a Vertragsende]: %', r.j; END IF;

  -- Beitragsaenderung mit Stichtag nach dem spaeter genannten Ende -> Kopf [x,x): das Ende bleibt D
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name', '__t_lvd_police_leer__', 'insurance_company', 'Beispiel AG', 'premium_amount', '20', 'schedule_unit', 'month',
    'debit_account_id', v_giro, 'first_payment_date', (t - 5)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [5 leer]: %', v_res; END IF;
  v_ins := (v_res->>'insurance_id')::int;
  v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id', v_ins, 'premium_amount', '25', 'effective_from', (t + 60)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [5 Beitrag]: %', v_res; END IF;
  v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id', v_ins, 'valid_to', (t + 30)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP [5 Ende vor Stichtag]: %', v_res; END IF;
  IF (SELECT last_valid_day FROM finance.active_insurances WHERE id = v_ins) IS DISTINCT FROM t + 30 THEN
    RAISE EXCEPTION 'FAIL [5b leerer Kopf]: %', (SELECT last_valid_day FROM finance.active_insurances WHERE id = v_ins); END IF;
  RAISE NOTICE 'PASS [5 active_insurances: Vertragsende D, auch mit leerem Kopf; valid_to bleibt]';

  -- ===== 6) Das Gesamtbild des Beraters =====
  v := finance.fn_advisor_snapshot();
  IF (SELECT (e->>'last_valid_day')::date FROM jsonb_array_elements(v->'recurring') e WHERE e->>'name' = '__t_lvd_abo__') IS DISTINCT FROM v_end THEN
    RAISE EXCEPTION 'FAIL [6a recurring]'; END IF;
  IF (SELECT (e->>'last_valid_day')::date FROM jsonb_array_elements(v->'planned_recurring') e WHERE e->>'name' = '__t_lvd_spaeter__') IS DISTINCT FROM t + 200 THEN
    RAISE EXCEPTION 'FAIL [6b planned_recurring]'; END IF;
  IF (SELECT (e->>'last_valid_day')::date FROM jsonb_array_elements(v->'standing_orders') e WHERE e->>'name' = '__t_lvd_so_raster__') IS DISTINCT FROM v_m2 + 5
     OR (SELECT (e->>'last_execution')::date FROM jsonb_array_elements(v->'standing_orders') e WHERE e->>'name' = '__t_lvd_so_raster__') IS DISTINCT FROM v_m2 THEN
    RAISE EXCEPTION 'FAIL [6c standing_orders]'; END IF;
  IF (SELECT (e->>'last_valid_day')::date FROM jsonb_array_elements(v->'insurances') e WHERE e->>'name' = '__t_lvd_police__') IS DISTINCT FROM v_end THEN
    RAISE EXCEPTION 'FAIL [6d insurances]'; END IF;
  IF v::text LIKE '%"valid_to"%' THEN RAISE EXCEPTION 'FAIL [6e Schluessel valid_to im Gesamtbild]'; END IF;
  RAISE NOTICE 'PASS [6 fn_advisor_snapshot: jede Liste traegt das Ende, kein valid_to]';
END $$;
ROLLBACK;
