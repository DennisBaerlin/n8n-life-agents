-- tests/db/finance/test_fn_set_loan.sql
-- Testet fn_set_loan: Konditionen, Rate-unter-Zins-Guard, Status-Kaskade, active-ohne-Rate-Guard, neg-Zins-Guard und
-- (WP2 "Finanzen schlank") die eine Quelle der Rate: Rate/Abbuchungstag aendern ueber die Raten-Kette mit Historie
-- (Split, Default-Stichtag, Korrektur in place), neue Kette fuer einen Kredit ohne Rate, Namenskopien, nachtragbare
-- Ursprungswerte nur bei zum Stichtag eroeffneten Krediten, Laufzeitende + Restschuld-Vorschau.
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_debit INT; v_loan INT; v_rp INT; v_new INT;
  v_irate NUMERIC; v_eff DATE; v_expect DATE;
  v_lstatus TEXT;
  v_loan2 INT; v_run INT; v_run_acc INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_sl_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_debit := (v_res->>'account_id')::int;

  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_loan__','lender','ING','borrower','Erika','original_amount',100000,
    'disbursement_date','2026-01-01','interest_rate',3.0,
    'monthly_annuity',1200,'schedule_day_of_month',1,'first_payment_date','2026-02-01','debit_account_id',v_debit
  )) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_rp   := (v_res->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN RAISE EXCEPTION 'FAIL set_loan [setup]: keine Kreditrate-recurring angelegt'; END IF;

  -- TEST 1: Zinssatz 3.0 -> 3.5
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', 3.5)) INTO v_res;
  SELECT interest_rate INTO v_irate FROM finance.loans WHERE id = v_loan;
  IF v_irate IS DISTINCT FROM 3.5 OR (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_rp THEN
    RAISE EXCEPTION 'FAIL set_loan [interest]: interest=% res=%', v_irate, v_res; END IF;
  RAISE NOTICE 'PASS set_loan [interest 3.5]';

  -- TEST 1b (Live-Befund 2026-10-24): Rate unter dem Monatszins aus der Restschuld -> ok:false ohne Write
  --   (100.000 * 3,5 % / 12 = 291,67)
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'monthly_annuity', 200)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'interest')::numeric IS DISTINCT FROM 291.67
     OR (SELECT monthly_annuity FROM finance.loan_overview WHERE id = v_loan) IS DISTINCT FROM 1200
     OR (SELECT count(*) FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))) <> 1 THEN
    RAISE EXCEPTION 'FAIL set_loan [rate < zins]: erwartet ok=false + interest 291.67 ohne Write, got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', 15)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [zins > rate]: erwartet ok=false, got %', v_res; END IF;
  -- Quartalsrate traegt drei Monatszinsen (fn_loan_period_months, wie jede Buchung): 500 < 3 x 291,67
  UPDATE finance.recurring_payments SET schedule_interval = 3 WHERE id = v_rp;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'monthly_annuity', 500)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'interest')::numeric IS DISTINCT FROM 875.00 THEN
    RAISE EXCEPTION 'FAIL set_loan [quartal]: erwartet ok=false + interest 875.00, got %', v_res; END IF;
  UPDATE finance.recurring_payments SET schedule_interval = 1 WHERE id = v_rp;
  RAISE NOTICE 'PASS set_loan [Rate < Monatszins -> ok:false, auch je Quartal]';

  -- TEST 2 (WP2): neuer Abbuchungstag -2 OHNE Stichtag -> Split zum naechsten noch nicht erledigten Termin ab heute;
  --   die Raten seit Februar (faellig, ungebucht) bleiben am alten Tag (Historie), der Kredit zeigt auf den neuen Kopf.
  v_expect := finance.fn_recurring_next_due(v_rp, core.fn_today());
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'schedule_day_of_month', -2)) INTO v_res;
  v_new := (v_res->>'recurring_payment_id')::int;
  v_eff := (v_res->>'effective_from')::date;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM true
     OR (v_res->>'previous_id')::int IS DISTINCT FROM v_rp OR v_new = v_rp
     OR v_eff IS DISTINCT FROM v_expect OR v_eff < core.fn_today() OR extract(day FROM v_eff) <> 1
     OR (SELECT recurring_payment_id FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM v_new
     OR (SELECT schedule_day_of_month FROM finance.recurring_payments WHERE id = v_new) IS DISTINCT FROM -2
     OR (SELECT schedule_day_of_month::text || '|' || valid_to FROM finance.recurring_payments WHERE id = v_rp)
        IS DISTINCT FROM '1|' || v_eff THEN
    RAISE EXCEPTION 'FAIL set_loan [dom -2 split]: got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [Abbuchungstag -2 -> neues Glied ab naechstem Termin, alte Termine bleiben am 1.]';

  -- TEST 3 (WP2): Rate 1200 -> 1000 ab 2027-01-01 (expliziter Stichtag) -> neues Glied; heute gilt noch 1.200
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'monthly_annuity', 1000, 'effective_from', '2027-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'effective_from')::date IS DISTINCT FROM '2027-01-01'
     OR (SELECT amount::text || '|' || valid_from FROM finance.recurring_payments
         WHERE id = (SELECT recurring_payment_id FROM finance.loans WHERE id = v_loan)) IS DISTINCT FROM '-1000.00|2027-01-01'
     OR (SELECT monthly_annuity FROM finance.loan_overview WHERE id = v_loan) IS DISTINCT FROM 1200.00
     OR (SELECT count(*) FROM finance.recurring_payments
         WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))) <> 3 THEN
    RAISE EXCEPTION 'FAIL set_loan [rate split]: got % / overview %', v_res,
      (SELECT monthly_annuity FROM finance.loan_overview WHERE id = v_loan); END IF;
  RAISE NOTICE 'PASS set_loan [Rate 1000 ab 2027-01-01 -> Historie, Uebersicht zeigt heute 1.200]';

  -- TEST 4: Status paused -> Kredit paused + alle noch laufenden Glieder paused (Kaskade ueber die Kette)
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'status', 'paused')) INTO v_res;
  SELECT status::text INTO v_lstatus FROM finance.loans WHERE id = v_loan;
  IF v_lstatus IS DISTINCT FROM 'paused' OR EXISTS (
       SELECT 1 FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))
          AND status = 'active' AND (valid_to IS NULL OR valid_to > core.fn_today())) THEN
    RAISE EXCEPTION 'FAIL set_loan [kaskade]: loan=% chain noch aktiv', v_lstatus; END IF;
  RAISE NOTICE 'PASS set_loan [status paused -> ganze Raten-Kette paused]';

  -- TEST 5: neg Zinssatz -> {ok:false}
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', -1)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [neg rate]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [neg rate -> ok:false]';

  -- TEST 6: Umbenennung fuehrt 'Kreditrate <Name>' (alle Glieder) und das Kreditkonto 'Kredit <Name>' mit
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'name', '__test_sl_neu__')) INTO v_res;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp))
             AND name <> 'Kreditrate __test_sl_neu__')
     OR (SELECT a.name FROM finance.accounts a JOIN finance.loans l ON l.loan_account_id = a.id WHERE l.id = v_loan)
        IS DISTINCT FROM 'Kredit __test_sl_neu__' THEN
    RAISE EXCEPTION 'FAIL set_loan [rename]: Namenskopien nicht mitgefuehrt'; END IF;
  RAISE NOTICE 'PASS set_loan [Umbenennung -> Kreditrate + Kreditkonto]';

  -- TEST 7: Kredit ohne Rate -> active ohne Rate ok:false; Rate ohne ersten Termin ok:false; mit Termin -> neue Kette, aktiv
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_paused__','lender','Family','borrower','Erika','original_amount',5000,
    'disbursement_date','2026-01-01','interest_rate',0.0,'debit_account_id',v_debit
  )) INTO v_res;
  v_loan2 := (v_res->>'loan_id')::int;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan2, 'status', 'active')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [active-no-annuity]: erwartet ok=false, got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan2, 'monthly_annuity', 200)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [rate ohne Termin]: erwartet ok=false, got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan2, 'monthly_annuity', 200,
    'effective_from', (core.fn_today() + 10)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT status::text FROM finance.loans WHERE id = v_loan2) IS DISTINCT FROM 'active'
     OR (SELECT name || '|' || amount || '|' || status FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int)
        IS DISTINCT FROM 'Kreditrate __test_sl_paused__|-200.00|active' THEN
    RAISE EXCEPTION 'FAIL set_loan [neue Kette]: got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [ohne Rate: active -> ok:false, Rate ohne Termin -> ok:false, mit Termin -> Kette + aktiv]';

  -- TEST 8: Ursprungswerte nur bei einem zum Stichtag eroeffneten Kredit
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'disbursement_date', '2025-12-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [frisch Ursprungswerte]: erwartet ok=false, got %', v_res; END IF;
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_run__','lender','Bank','current_balance',40000,'interest_rate',2.0,
    'monthly_annuity',400,'first_payment_date',(core.fn_today() + 15)::text,'debit_account_id',v_debit)) INTO v_res;
  v_run := (v_res->>'loan_id')::int;
  v_run_acc := (v_res->>'loan_account_id')::int;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'disbursement_date', (core.fn_today() + 1)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [Datum Zukunft]: erwartet ok=false, got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'original_amount', 30000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'opening_remaining_debt')::numeric IS DISTINCT FROM 40000 THEN
    RAISE EXCEPTION 'FAIL set_loan [Betrag < Eroeffnung]: got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'original_amount', 60000, 'disbursement_date', '2019-03-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT original_amount::text || '|' || disbursement_date FROM finance.loans WHERE id = v_run) IS DISTINCT FROM '60000.00|2019-03-01'
     OR finance.fn_get_balance(v_run_acc) IS DISTINCT FROM -40000.00 THEN
    RAISE EXCEPTION 'FAIL set_loan [Ursprungswerte nachtragen]: got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [Ursprungswerte: frisch ok:false, Zukunft/zu klein ok:false, laufend nachgetragen ohne Buchung]';

  -- TEST 9: Laufzeit -- Laufzeitende vor Zinsbindung ok:false; gueltig -> gespeichert + Vorschau im Return
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'interest_rate_fixed_until', '2031-01-01',
    'term_end_date', '2030-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_loan [Laufzeit < Zinsbindung]: got %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'interest_rate_fixed_until', (core.fn_today() + 365)::text,
    'term_end_date', (core.fn_today() + 3650)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR NOT ((v_res->>'balance_at_fixed_until')::numeric BETWEEN 35000 AND 40000)
     OR (v_res->>'balance_at_term_end')::numeric IS DISTINCT FROM 0
     OR (SELECT term_end_date FROM finance.loans WHERE id = v_run) IS DISTINCT FROM core.fn_today() + 3650 THEN
    RAISE EXCEPTION 'FAIL set_loan [Laufzeit]: got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [Laufzeitende + Restschuld-Vorschau]';

  -- TEST 10: Korrektur direkt nach der Anlage (noch nichts faellig) -> in place, keine Historie
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_run, 'monthly_annuity', 450)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'split')::boolean IS DISTINCT FROM false
     OR (SELECT count(*) FROM finance.recurring_payments
         WHERE id IN (SELECT finance.fn_recurring_lineage((v_res->>'recurring_payment_id')::int))) <> 1
     OR (SELECT monthly_annuity FROM finance.loan_overview WHERE id = v_run) IS DISTINCT FROM 450.00 THEN
    RAISE EXCEPTION 'FAIL set_loan [Korrektur in place]: got %', v_res; END IF;
  RAISE NOTICE 'PASS set_loan [Korrektur ohne faellige Rate -> in place]';
END $$;

ROLLBACK;
