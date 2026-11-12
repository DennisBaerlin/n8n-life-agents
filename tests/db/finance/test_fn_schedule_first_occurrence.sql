-- tests/db/finance/test_fn_schedule_first_occurrence.sql
-- finance.fn_schedule_first_occurrence + ihre Konsumenten neben fn_create_recurring_payment (dort eigener Test
-- test_fn_create_recurring_payment_anchor.sql): fn_create_insurance, fn_create_pension, fn_create_savings_plan,
-- fn_create_recurring_transfer verankern first_payment_date auf den ersten Termin >= Eingabe mit dem festen Monatstag;
-- valid_from ohne eigene Angabe folgt; effective meldet first_payment_date wie gespeichert.
--   1) Helfer direkt: vor/gleich/nach dem Tag, -1, -2, ohne Tag, feste Monatstage, Woche (Anker bleibt)
--   2) je Konsument: dieselben Faelle (Datum der Kette = verankert, valid_from folgt, effective = gespeichert)
--   3) explizites valid_from bleibt (Versicherung = Vertragsbeginn, Dauerauftrag)
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro  int;
  v_save  int;
  v_depot int;
  v_res   jsonb;
  v_case  record;
  v_rp    record;
  v_rp_id int;
  v_n     int := 0;
BEGIN
  -- (1) Helfer
  IF finance.fn_schedule_first_occurrence('2026-11-12', 1, 'month', 1::smallint, NULL) IS DISTINCT FROM '2026-12-01'::date
     OR finance.fn_schedule_first_occurrence('2026-11-01', 1, 'month', 1::smallint, NULL) IS DISTINCT FROM '2026-11-01'::date
     OR finance.fn_schedule_first_occurrence('2026-11-12', 1, 'month', 15::smallint, NULL) IS DISTINCT FROM '2026-11-15'::date
     OR finance.fn_schedule_first_occurrence('2026-11-12', 1, 'month', (-1)::smallint, NULL) IS DISTINCT FROM '2026-11-30'::date
     OR finance.fn_schedule_first_occurrence('2026-11-30', 1, 'month', (-2)::smallint, NULL) IS DISTINCT FROM '2026-12-30'::date
     OR finance.fn_schedule_first_occurrence('2026-11-12', 1, 'month', NULL, NULL) IS DISTINCT FROM '2026-11-12'::date
     OR finance.fn_schedule_first_occurrence('2026-11-12', 1, 'month', NULL, ARRAY[2, 16]::smallint[]) IS DISTINCT FROM '2026-11-16'::date
     OR finance.fn_schedule_first_occurrence('2026-11-12', 2, 'week', 1::smallint, NULL) IS DISTINCT FROM '2026-11-12'::date
     OR finance.fn_schedule_first_occurrence(NULL, 1, 'month', 1::smallint, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1] Helfer liefert nicht den ersten Rastertermin'; END IF;
  RAISE NOTICE 'PASS [1] Helfer';

  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_anc_giro', 'cash') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_anc_save', 'cash') RETURNING id INTO v_save;
  INSERT INTO finance.accounts (name, account_type, settlement_account_id) VALUES ('__t_anc_depot', 'stocks_depot', v_giro)
    RETURNING id INTO v_depot;

  -- (2) je Konsument
  FOR v_case IN SELECT * FROM (VALUES
      ('nach', '2026-11-12', '1',  '2026-12-01'),
      ('gleich','2026-11-01', '1',  '2026-11-01'),
      ('vor',  '2026-11-12', '15', '2026-11-15'),
      ('letzter','2026-11-12', '-1', '2026-11-30'),
      ('vorletzter','2026-11-30', '-2', '2026-12-30'),
      ('ohne', '2026-11-12', '',   '2026-11-12')
    ) AS t(label, first_in, dom, expected)
  LOOP
    v_n := v_n + 1;

    -- Versicherung
    v_res := finance.fn_create_insurance(jsonb_build_object(
      'name', '__t_anc_ins ' || v_case.label, 'premium_amount', 10, 'schedule_unit', 'month',
      'schedule_day_of_month', v_case.dom, 'first_payment_date', v_case.first_in, 'debit_account_id', v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 ins %] %', v_case.label, v_res; END IF;
    SELECT r.first_payment_date, r.valid_from, i.valid_from AS ins_from INTO v_rp
      FROM finance.insurances i JOIN finance.recurring_payments r ON r.id = i.recurring_payment_id
     WHERE i.id = (v_res->>'insurance_id')::int;
    IF v_rp.first_payment_date IS DISTINCT FROM v_case.expected::date OR v_rp.valid_from IS DISTINCT FROM v_case.expected::date
       OR v_rp.ins_from IS DISTINCT FROM v_case.expected::date
       OR v_res->'effective'->>'first_payment_date' IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'FAIL [2 ins %] gespeichert % / % / Vertrag %, effective %, erwartet %',
        v_case.label, v_rp.first_payment_date, v_rp.valid_from, v_rp.ins_from, v_res->'effective', v_case.expected; END IF;

    -- Altersvorsorge mit Beitrag
    v_res := finance.fn_create_pension(jsonb_build_object(
      'name', '__t_anc_pen ' || v_case.label, 'pension_type', 'ruerup', 'current_value', 1000,
      'contribution_amount', 20, 'debit_account_id', v_giro,
      'schedule_day_of_month', v_case.dom, 'first_payment_date', v_case.first_in));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 pen %] %', v_case.label, v_res; END IF;
    SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments
     WHERE id = (v_res->>'recurring_payment_id')::int;
    IF v_rp.first_payment_date IS DISTINCT FROM v_case.expected::date OR v_rp.valid_from IS DISTINCT FROM v_case.expected::date
       OR v_res->'effective'->>'first_payment_date' IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'FAIL [2 pen %] gespeichert % / %, effective %, erwartet %',
        v_case.label, v_rp.first_payment_date, v_rp.valid_from, v_res->'effective', v_case.expected; END IF;

    -- Dauerauftrag zwischen eigenen Konten
    v_res := finance.fn_create_recurring_transfer(jsonb_build_object(
      'name', '__t_anc_trf ' || v_case.label, 'from_account_id', v_giro, 'to_account_id', v_save, 'amount', 30,
      'schedule_unit', 'month', 'schedule_day_of_month', v_case.dom, 'first_payment_date', v_case.first_in));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 trf %] %', v_case.label, v_res; END IF;
    SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments
     WHERE id = (v_res->>'recurring_payment_id')::int;
    IF v_rp.first_payment_date IS DISTINCT FROM v_case.expected::date OR v_rp.valid_from IS DISTINCT FROM v_case.expected::date
       OR v_res->'effective'->>'first_payment_date' IS DISTINCT FROM v_case.expected
       OR v_res->'effective'->>'valid_from' IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'FAIL [2 trf %] gespeichert % / %, effective %, erwartet %',
        v_case.label, v_rp.first_payment_date, v_rp.valid_from, v_res->'effective', v_case.expected; END IF;

    -- Sparplan (fester Monatstag, Depot ohne festen Ausfuehrungskalender)
    v_res := finance.fn_create_savings_plan(jsonb_build_object(
      'name', '__t_anc_sp ' || v_case.label, 'depot_name', '__t_anc_depot', 'isin', 'IE00B3RBWM25', 'symbol', 'VWCE',
      'security_name', 'Testfonds', 'amount', 25, 'schedule_interval', 1, 'schedule_unit', 'month',
      'schedule_day_of_month', v_case.dom, 'first_payment_date', v_case.first_in, 'depot_execution_days', 'none'));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 sp %] %', v_case.label, v_res; END IF;
    SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments
     WHERE id = (v_res->>'recurring_payment_id')::int;
    IF v_rp.first_payment_date IS DISTINCT FROM v_case.expected::date OR v_rp.valid_from IS DISTINCT FROM v_case.expected::date
       OR v_res->'effective'->>'first_payment_date' IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'FAIL [2 sp %] gespeichert % / %, effective %, erwartet %',
        v_case.label, v_rp.first_payment_date, v_rp.valid_from, v_res->'effective', v_case.expected; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [2] Versicherung, Altersvorsorge, Dauerauftrag, Sparplan verankert (% Faelle)', v_n;

  -- (3) explizites valid_from bleibt
  v_res := finance.fn_create_insurance(jsonb_build_object(
    'name', '__t_anc_ins explizit', 'premium_amount', 10, 'schedule_unit', 'month', 'schedule_day_of_month', 1,
    'first_payment_date', '2026-11-12', 'valid_from', '2026-11-05', 'debit_account_id', v_giro));
  SELECT r.first_payment_date, i.valid_from AS ins_from INTO v_rp
    FROM finance.insurances i JOIN finance.recurring_payments r ON r.id = i.recurring_payment_id
   WHERE i.id = (v_res->>'insurance_id')::int;
  IF v_rp.first_payment_date IS DISTINCT FROM '2026-12-01'::date OR v_rp.ins_from IS DISTINCT FROM '2026-11-05'::date THEN
    RAISE EXCEPTION 'FAIL [3 ins] first % Vertragsbeginn %', v_rp.first_payment_date, v_rp.ins_from; END IF;
  v_res := finance.fn_create_recurring_transfer(jsonb_build_object(
    'name', '__t_anc_trf explizit', 'from_account_id', v_giro, 'to_account_id', v_save, 'amount', 30,
    'schedule_unit', 'month', 'schedule_day_of_month', 1, 'first_payment_date', '2026-11-12', 'valid_from', '2026-11-20'));
  SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_rp.first_payment_date IS DISTINCT FROM '2026-12-01'::date OR v_rp.valid_from IS DISTINCT FROM '2026-11-20'::date THEN
    RAISE EXCEPTION 'FAIL [3 trf] first % valid_from %', v_rp.first_payment_date, v_rp.valid_from; END IF;
  RAISE NOTICE 'PASS [3] explizites valid_from bleibt';
END $$;
ROLLBACK;
