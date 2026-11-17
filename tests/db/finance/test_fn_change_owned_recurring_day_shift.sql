-- tests/db/finance/test_fn_change_owned_recurring_day_shift.sql
-- Eigenschaft wie test_fn_set_recurring_payment_day_shift, fuer entitaets-besessene Raten-Ketten (fn_change_owned_recurring,
-- hier ueber fn_set_loan): ein neuer Abbuchungstag behaelt in jedem Monat genau eine Rate; effective_from ist der
-- gespeicherte Start der Zeile mit dem neuen Tag (Karte/Antwort lesen ihn).
BEGIN;

CREATE FUNCTION pg_temp.occ_set(p_rp int, p_from date, p_until date) RETURNS SETOF date LANGUAGE sql AS $$
    SELECT o.due_date FROM finance.fn_recurring_due_open(p_from, p_until) o
    WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp));
$$;

DO $$
DECLARE
  v_res JSONB; v_debit INT; v_loan INT; v_rp INT; c1 INT; v_txt TEXT; v_from DATE;
  m0 DATE := date_trunc('month', core.fn_today())::date;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_cod_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_debit := (v_res->>'account_id')::int;

  -- TEST 1: Kredit, erste Rate 2031-01-25 (noch nichts faellig), Tag -> 20. in place: Januar bleibt, 12 Raten 2031
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_cod_loan_a__','lender','Buchenbank','borrower','Test',
    'original_amount',50000,'disbursement_date',(m0 - interval '1 month')::date,'interest_rate',3.0,'monthly_annuity',600,
    'schedule_day_of_month',25,'first_payment_date','2031-01-25','debit_account_id',v_debit)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL change_owned [Setup a]: %', v_res; END IF;
  v_loan := (v_res->>'loan_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'schedule_day_of_month', 20)) INTO v_res;
  SELECT count(*)::int, min(d)::text INTO c1, v_txt FROM pg_temp.occ_set(v_rp, '2031-01-01', '2031-12-31') d;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM false
     OR c1 <> 12 OR v_txt IS DISTINCT FROM '2031-01-20'
     OR (v_res->>'effective_from')::date IS DISTINCT FROM (SELECT valid_from FROM finance.recurring_payments WHERE id = v_rp) THEN
    RAISE EXCEPTION 'FAIL change_owned [in place]: % -> % Raten, erste % (erwartet 12, 2031-01-20, effective_from = gespeicherter Start)', v_res, c1, v_txt; END IF;
  RAISE NOTICE 'PASS change_owned [Kredit in place: Januar bleibt am 20.]';

  -- TEST 2: Kredit mit ueberfaelligen Raten (seit m-2 am 25.), Tag -> 20.: Split; kein Monat faellt aus oder kommt doppelt,
  --         effective_from = gespeicherter Start der neuen Zeile (ein 20.)
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_cod_loan_b__','lender','Buchenbank','borrower','Test',
    'original_amount',50000,'disbursement_date',(m0 - interval '3 months')::date,'interest_rate',3.0,'monthly_annuity',600,
    'schedule_day_of_month',25,'first_payment_date',(m0 - interval '2 months' + interval '24 days')::date,
    'debit_account_id',v_debit)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL change_owned [Setup b]: %', v_res; END IF;
  v_loan := (v_res->>'loan_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'schedule_day_of_month', 20)) INTO v_res;
  SELECT valid_from INTO v_from FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int;
  SELECT count(*)::int INTO c1 FROM pg_temp.occ_set(v_rp, (m0 - interval '2 months')::date, (m0 + interval '10 months' - interval '1 day')::date);
  IF (v_res->>'split')::boolean IS DISTINCT FROM true OR c1 <> 12
     OR EXISTS (SELECT 1 FROM pg_temp.occ_set(v_rp, (m0 - interval '2 months')::date, (m0 + interval '10 months')::date) d
                GROUP BY date_trunc('month', d) HAVING count(*) > 1)
     OR (v_res->>'effective_from')::date IS DISTINCT FROM v_from OR extract(day FROM v_from) <> 20 THEN
    RAISE EXCEPTION 'FAIL change_owned [Split]: % -> % Raten, Start % (erwartet 12, je Monat eine, effective_from = Start am 20.)',
      v_res, c1, v_from; END IF;
  RAISE NOTICE 'PASS change_owned [Kredit mit ueberfaelligen Raten: Split ohne Luecke, effective_from = echter Start]';
END $$;

ROLLBACK;
