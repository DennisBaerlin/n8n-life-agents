-- tests/db/finance/test_fn_create_recurring_payment_anchor.sql
-- finance.fn_create_recurring_payment: passt first_payment_date nicht zum festen Monatstag (schedule_day_of_month), verankert
-- die fn auf den ersten Termin >= first_payment_date mit diesem Tag (dasselbe Raster wie finance.fn_schedule_occurrences);
-- valid_from ohne eigene Angabe folgt dem verankerten Termin. Probelauf (effective) und Write zeigen dasselbe Datum.
--   1) vor / gleich / nach dem Monatstag, -1 (Monatsletzter), -2 (vorletzter Tag), ohne Monatstag (Anker bleibt)
--   2) explizites valid_from bleibt unveraendert
--   3) effective meldet first_payment_date und valid_from so, wie sie gespeichert werden
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_acct int;
  v_res  jsonb;
  v_case record;
  v_rp   record;
BEGIN
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_anchor_giro', 'cash') RETURNING id INTO v_acct;

  FOR v_case IN SELECT * FROM (VALUES
      ('nach dem Tag',    '2026-11-12', '1',  '2026-12-01'),
      ('gleich dem Tag',  '2026-11-01', '1',  '2026-11-01'),
      ('vor dem Tag',     '2026-11-12', '15', '2026-11-15'),
      ('Monatsletzter',   '2026-11-12', '-1', '2026-11-30'),
      ('am Monatsletzten','2026-11-30', '-1', '2026-11-30'),
      ('vorletzter Tag',  '2026-11-30', '-2', '2026-12-30'),
      ('ohne Monatstag',  '2026-11-12', '',   '2026-11-12')
    ) AS t(label, first_in, dom, expected)
  LOOP
    v_res := finance.fn_create_recurring_payment(jsonb_build_object(
      'name', '__t_anchor ' || v_case.label, 'account_id', v_acct, 'direction', 'income', 'amount', 100,
      'schedule_unit', 'month', 'schedule_day_of_month', v_case.dom, 'first_payment_date', v_case.first_in));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [1 %] Write abgelehnt: %', v_case.label, v_res; END IF;
    SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments
     WHERE id = (v_res->>'recurring_payment_id')::int;
    IF v_rp.first_payment_date IS DISTINCT FROM v_case.expected::date THEN
      RAISE EXCEPTION 'FAIL [1 %] first_payment_date % statt %', v_case.label, v_rp.first_payment_date, v_case.expected; END IF;
    IF v_rp.valid_from IS DISTINCT FROM v_case.expected::date THEN
      RAISE EXCEPTION 'FAIL [1 %] valid_from % statt % (folgt dem verankerten Termin)', v_case.label, v_rp.valid_from, v_case.expected; END IF;
    IF v_res->'effective'->>'first_payment_date' IS DISTINCT FROM v_case.expected
       OR v_res->'effective'->>'valid_from' IS DISTINCT FROM v_case.expected THEN
      RAISE EXCEPTION 'FAIL [3 %] effective % meldet nicht das gespeicherte Datum %', v_case.label, v_res->'effective', v_case.expected; END IF;
  END LOOP;
  RAISE NOTICE 'PASS [1+3] Verankerung auf den Monatstag (vor/gleich/nach, -1, -2, ohne), effective = gespeichert';

  -- (2) explizites valid_from bleibt
  v_res := finance.fn_create_recurring_payment(jsonb_build_object(
    'name', '__t_anchor explizit', 'account_id', v_acct, 'direction', 'income', 'amount', 100,
    'schedule_unit', 'month', 'schedule_day_of_month', 1, 'first_payment_date', '2026-11-12', 'valid_from', '2026-11-20'));
  SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_rp.first_payment_date IS DISTINCT FROM '2026-12-01'::date OR v_rp.valid_from IS DISTINCT FROM '2026-11-20'::date THEN
    RAISE EXCEPTION 'FAIL [2] explizites valid_from: first % valid_from %', v_rp.first_payment_date, v_rp.valid_from; END IF;
  RAISE NOTICE 'PASS [2] explizites valid_from bleibt, nur der Anker wandert';
END $$;
ROLLBACK;
