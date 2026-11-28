-- tests/db/finance/test_fn_split_recurring_payment_rhythm_anchor.sql
-- Eigenschaft: Bei einem Rhythmus-Wechsel mit festem Tag verankert der Split die neue Zeile am ersten Termin ab dem
-- Stichtag (nie ein Intervall spaeter, nicht am Stichtag selbst): monatlich am 1. -> "alle 3 Monate am 1." ab 10.02.:
-- alter Termin 01.02. (vor dem Stichtag), neue Termine 01.03. und 01.06. Gegenstueck zum Anlegen: test_prop_first_due_multi_month.
BEGIN;
DO $$
DECLARE
  v_acct INT; v_rp INT; v_res JSONB; v_new INT; v_txt TEXT; v_anchor DATE;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__sra_acct__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_acct;
  v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__sra_pay__','account_id',v_acct,'direction','expense',
    'amount',50,'schedule_unit','month','schedule_interval',1,'schedule_day_of_month',1,'first_payment_date','2031-01-01'));
  v_rp := (v_res->>'recurring_payment_id')::int;
  v_res := finance.fn_split_recurring_payment(v_rp, DATE '2031-02-10', NULL, 3::smallint, 'month'::finance.schedule_unit,
                                              1::smallint, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL split rhythm [ok]: %', v_res; END IF;
  v_new := (v_res->>'recurring_payment_id')::int;
  SELECT first_payment_date INTO v_anchor FROM finance.recurring_payments WHERE id = v_new;
  SELECT string_agg(o.due_date::text, ',' ORDER BY o.due_date) INTO v_txt
  FROM finance.fn_recurring_due_open('2031-01-01', '2031-12-31') o
  WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_new)) AND o.due_date < '2031-08-01';
  IF v_anchor IS DISTINCT FROM DATE '2031-03-01' OR v_txt IS DISTINCT FROM '2031-01-01,2031-02-01,2031-03-01,2031-06-01' THEN
    RAISE EXCEPTION 'FAIL split rhythm [Anker/Termine]: Anker %, Termine % (erwartet 2031-03-01 und 01.01.,01.02.,01.03.,01.06.)', v_anchor, v_txt;
  END IF;
  RAISE NOTICE 'PASS split rhythm [neuer Anker = erster Termin ab Stichtag]';
END $$;
ROLLBACK;
