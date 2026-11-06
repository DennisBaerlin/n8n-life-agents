-- tests/db/finance/test_fn_book_loan_payment.sql
-- Testet fn_book_loan_payment: 2 Transaktionen, Zins/Tilgung, auto-Berechnung, Guard
BEGIN;

DO $$
DECLARE
  v_result      JSONB;
  v_debit_id    INT;
  v_loan_id     INT;
  v_loan_acc    INT;
  v_pay_tx_id   INT;
  v_prin_tx_id  INT;
  v_payment     NUMERIC := 500;
  v_interest_rate NUMERIC := 3.0;  -- 3 % p.a.
  v_current_bal NUMERIC := 10000;  -- Restschuld
  v_exp_interest NUMERIC;
  v_exp_principal NUMERIC;
  v_got_debit_bal NUMERIC;
  v_got_loan_bal  NUMERIC;
BEGIN

  -- Setup: Girokonto (Abbuchungskonto fuer die Rate)
  SELECT finance.fn_create_account(
    '{"name":"__test_loanpay_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit_id := (v_result->>'account_id')::int;

  -- Setup: Kredit anlegen (Restschuld = 10000, Zinssatz 3%)
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name',              '__test_loanpay_kredit__',
    'lender',            'Testbank',
    'borrower',          'Test',
    'original_amount',   v_current_bal,
    'current_balance',   v_current_bal,
    'disbursement_date', CURRENT_DATE::text,
    'interest_rate',     v_interest_rate,
    'monthly_annuity',   v_payment,
    'schedule_day_of_month', '1',
    'first_payment_date', CURRENT_DATE::text,
    'debit_account_id',  v_debit_id
  )) INTO v_result;
  v_loan_id  := (v_result->>'loan_id')::int;
  v_loan_acc := (v_result->>'loan_account_id')::int;

  -- Erwartete Werte (Auto-Berechnung)
  v_exp_interest  := ROUND(v_current_bal * v_interest_rate / 1200.0, 2);  -- 25.00
  v_exp_principal := v_payment - v_exp_interest;                           -- 475.00

  -- TEST 1: Zahlung ohne expliziten principal_amount (auto-Berechnung)
  SELECT finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',          v_loan_id,
    'loan_account_id',  v_loan_acc,
    'debit_account_id', v_debit_id,
    'payment_amount',   v_payment,
    'payment_date',     CURRENT_DATE::text
  )) INTO v_result;

  IF NOT (v_result ? 'loan_payment_tx_id') OR NOT (v_result ? 'principal_tx_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment: fehlende IDs im Result, got %', v_result;
  END IF;
  v_pay_tx_id  := (v_result->>'loan_payment_tx_id')::int;
  v_prin_tx_id := (v_result->>'principal_tx_id')::int;

  -- Assert: zurueckgegebene Zins/Tilgung-Werte
  IF (v_result->>'interest_portion')::numeric IS DISTINCT FROM v_exp_interest THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [interest_portion]: erwartet %, got %',
      v_exp_interest, v_result->>'interest_portion';
  END IF;
  IF (v_result->>'principal_amount')::numeric IS DISTINCT FROM v_exp_principal THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [principal_amount]: erwartet %, got %',
      v_exp_principal, v_result->>'principal_amount';
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [auto-Berechnung]: interest=%, principal=%',
    v_exp_interest, v_exp_principal;

  -- Assert: Girokonto-Balance = -initial_loan_bal - payment
  -- (Girokonto: 0 zu Beginn; fn_create_loan bucht -v_current_bal auf loan_acc, nicht auf debit)
  SELECT finance.fn_get_balance(v_debit_id) INTO v_got_debit_bal;
  IF v_got_debit_bal IS DISTINCT FROM -v_payment THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [debit_bal]: erwartet %, got %',
      -v_payment, v_got_debit_bal;
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [debit_bal]: %', v_got_debit_bal;

  -- Assert: Kredit-Balance = -10000 (Ereoeffnung) + principal
  SELECT finance.fn_get_balance(v_loan_acc) INTO v_got_loan_bal;
  IF v_got_loan_bal IS DISTINCT FROM (-v_current_bal + v_exp_principal) THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [loan_bal]: erwartet %, got %',
      -v_current_bal + v_exp_principal, v_got_loan_bal;
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [loan_bal]: %', v_got_loan_bal;

  -- Assert: Post-State-Vertrag — remaining_debt nach Tilgung im Return (= Restschuld - Tilgung)
  IF (v_result->>'remaining_debt')::numeric IS DISTINCT FROM (v_current_bal - v_exp_principal) THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [return remaining_debt]: erwartet %, got %',
      (v_current_bal - v_exp_principal), v_result->>'remaining_debt';
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [remaining_debt]: %', v_result->>'remaining_debt';

  -- Assert: Transaktions-Kategorien korrekt
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_pay_tx_id AND category = 'loan_payment' AND amount = -v_payment
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment: loan_payment TX fehlt oder falscher Betrag';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_prin_tx_id AND category = 'principal' AND amount = v_exp_principal
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment: principal TX fehlt oder falscher Betrag';
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [TX-Kategorien korrekt]';

  -- TEST 2: Expliziter principal_amount (z.B. Sondertilgung)
  SELECT finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',          v_loan_id,
    'loan_account_id',  v_loan_acc,
    'debit_account_id', v_debit_id,
    'payment_amount',   1000,
    'payment_date',     CURRENT_DATE::text,
    'principal_amount', 980
  )) INTO v_result;
  IF (v_result->>'interest_portion')::numeric IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [explizit_principal]: interest erwartet 20, got %',
      v_result->>'interest_portion';
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [explizit_principal]: interest=%', v_result->>'interest_portion';

  -- TEST 3: Unterzahlung (Rate < Zins -> negativer Tilgungsanteil) -> {ok:false}
  SELECT finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',          v_loan_id,
    'loan_account_id',  v_loan_acc,
    'debit_account_id', v_debit_id,
    'payment_amount',   10,
    'payment_date',     CURRENT_DATE::text,
    'principal_amount', -50
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [underpay]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [underpay -> ok:false]: %', v_result->>'reason';

  -- TEST 4: Ueberzahlung (Tilgung > Restschuld) -> {ok:false} mit payoff_amount
  SELECT finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',          v_loan_id,
    'loan_account_id',  v_loan_acc,
    'debit_account_id', v_debit_id,
    'payment_amount',   20000,
    'payment_date',     CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [overpay]: erwartet ok=false, got %', v_result;
  END IF;
  IF NOT (v_result ? 'payoff_amount') THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [overpay]: payoff_amount fehlt, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [overpay -> ok:false, payoff=%]', v_result->>'payoff_amount';

  -- TEST 5: payment <= 0 -> {ok:false}
  SELECT finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',          v_loan_id,
    'loan_account_id',  v_loan_acc,
    'debit_account_id', v_debit_id,
    'payment_amount',   0,
    'payment_date',     CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_loan_payment [payment<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_loan_payment [payment<=0 -> ok:false]';

END $$;

-- TEST 6-9 (Audit F1b): regulaere Rate schliesst das passende Vorkommen der Kredit-rp (sonst bot die Erinnerung
--   die schon bezahlte Rate erneut an -> Doppelbuchung). Nur das NAECHSTGELEGENE Vorkommen innerhalb eines Monats,
--   nie still um Monate rueckdatiert; abweichende Betraege (Sondertilgung) bleiben ungestempelt.
DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_loan  INT;
  v_lacc  INT;
  v_rp    INT;
  v_f     DATE := (CURRENT_DATE - interval '2 months')::date - 5;   -- Anker: Vorkommen f, f+1M, f+2M (= heute-5..)
  v_d3    DATE;
  v_d2    DATE;
  c       INT;
  v_rpid  INT;
  v_date  DATE;
BEGIN
  v_d2 := (v_f + interval '1 month')::date;
  v_d3 := (v_f + interval '2 months')::date;
  SELECT finance.fn_create_account('{"name":"__test_lp2_giro__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_lp2_kredit__','lender','B','borrower','T',
    'original_amount',200000,'current_balance',200000,'disbursement_date',(v_f - 30)::text,'interest_rate',3.6,
    'monthly_annuity',1000,'first_payment_date',v_f::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;

  -- TEST 6: regulaere Rate heute -> stempelt das naechstgelegene offene Vorkommen (v_d3) und bucht auf dessen Datum
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro,
    'payment_amount',1000,'payment_date',CURRENT_DATE::text)) INTO v_res;
  SELECT recurring_payment_id, transaction_date INTO v_rpid, v_date FROM finance.transactions WHERE id = (v_res->>'loan_payment_tx_id')::int;
  IF (v_res->>'matched_due_date')::date IS DISTINCT FROM v_d3 OR v_rpid IS DISTINCT FROM v_rp OR v_date IS DISTINCT FROM v_d3 THEN
    RAISE EXCEPTION 'FAIL loan [match]: matched=% rp=% date=% (erwartet %/%/%)', v_res->>'matched_due_date', v_rpid, v_date, v_d3, v_rp, v_d3; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_rp AND due_date = v_d3) THEN
    RAISE EXCEPTION 'FAIL loan [match]: bezahlte Rate % noch offen in der Erinnerung', v_d3; END IF;
  IF (v_res->>'principal_amount')::numeric IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'FAIL loan [match]: Tilgung erwartet 400 (Zins 600), got %', v_res->>'principal_amount'; END IF;
  RAISE NOTICE 'PASS loan [regulaere Rate schliesst naechstgelegenes Vorkommen, Tilgung 400]';

  -- TEST 7: noch eine regulaere Rate heute -> das naechste offene Vorkommen (v_d2) liegt > 1 Monat zurueck ->
  --   KEIN stilles Rueckdatieren: ungestempelt am payment_date
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro,
    'payment_amount',1000,'payment_date',CURRENT_DATE::text)) INTO v_res;
  SELECT recurring_payment_id, transaction_date INTO v_rpid, v_date FROM finance.transactions WHERE id = (v_res->>'loan_payment_tx_id')::int;
  IF v_res->>'matched_due_date' IS NOT NULL OR v_rpid IS NOT NULL OR v_date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL loan [kein Rueckdatieren]: matched=% rp=% date=%', v_res->>'matched_due_date', v_rpid, v_date; END IF;
  RAISE NOTICE 'PASS loan [aeltere offene Rate wird nicht still rueckdatiert]';

  -- TEST 8: Sondertilgung (Betrag <> Rate) -> ungestempelt
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro,
    'payment_amount',5000,'payment_date',CURRENT_DATE::text)) INTO v_res;
  SELECT recurring_payment_id INTO v_rpid FROM finance.transactions WHERE id = (v_res->>'loan_payment_tx_id')::int;
  IF v_rpid IS NOT NULL OR v_res->>'matched_due_date' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL loan [Sondertilgung]: darf kein Vorkommen stempeln, got rp=%', v_rpid; END IF;
  RAISE NOTICE 'PASS loan [Sondertilgung bleibt ungestempelt]';

  -- TEST 9: explizite Faelligkeit (Scheduler-Pfad) -> genau dieses Vorkommen
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro,
    'payment_amount',1000,'payment_date',v_d2::text,'due_date',v_d2::text)) INTO v_res;
  SELECT recurring_payment_id, transaction_date INTO v_rpid, v_date FROM finance.transactions WHERE id = (v_res->>'loan_payment_tx_id')::int;
  IF v_rpid IS DISTINCT FROM v_rp OR v_date IS DISTINCT FROM v_d2 OR (v_res->>'matched_due_date')::date IS DISTINCT FROM v_d2 THEN
    RAISE EXCEPTION 'FAIL loan [explizit]: rp=% date=% matched=%', v_rpid, v_date, v_res->>'matched_due_date'; END IF;
  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_rp;
  IF c <> 1 THEN RAISE EXCEPTION 'FAIL loan [explizit]: erwartet 1 offenes Vorkommen (%), got %', v_f, c; END IF;
  RAISE NOTICE 'PASS loan [explizite Faelligkeit stempelt genau dieses Vorkommen]';

  -- TEST 10 (Review): explizite, schon gebuchte Faelligkeit -> ok:false (Race-Backstop nach dem Lock, unabhaengig
  --   vom Belastungskonto -- der Unique-Index greift nur bei gleichem account_id)
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,
    'debit_account_id',(finance.fn_create_account('{"name":"__test_lp2_giro2__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int,
    'payment_amount',1000,'payment_date',v_d2::text,'due_date',v_d2::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL loan [schon gebucht, anderes Konto]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS loan [explizite, schon gebuchte Faelligkeit -> ok:false]';
END $$;

-- TEST 11 (Review): regulaere Rate ein paar Tage VOR der Faelligkeit bezahlt -> trotzdem dem Vorkommen zugeordnet
--   (sonst fragt die Erinnerung am Faelligkeitstag erneut -> Doppelbuchung)
DO $$
DECLARE
  v_res JSONB; v_giro INT; v_loan INT; v_lacc INT; v_rp INT; v_rpid INT; v_date DATE;
  v_due DATE := CURRENT_DATE + 3;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_lp3_giro__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_lp3_kredit__','lender','B','borrower','T',
    'original_amount',50000,'current_balance',50000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',2.4,
    'monthly_annuity',500,'first_payment_date',v_due::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int; v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;
  SELECT finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro,
    'payment_amount',500,'payment_date',CURRENT_DATE::text)) INTO v_res;
  SELECT recurring_payment_id, transaction_date INTO v_rpid, v_date FROM finance.transactions WHERE id = (v_res->>'loan_payment_tx_id')::int;
  IF v_rpid IS DISTINCT FROM v_rp OR v_date IS DISTINCT FROM v_due THEN
    RAISE EXCEPTION 'FAIL loan [frueh bezahlt]: rp=% date=% (erwartet %/%)', v_rpid, v_date, v_rp, v_due; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(v_due) WHERE recurring_payment_id = v_rp AND due_date = v_due) THEN
    RAISE EXCEPTION 'FAIL loan [frueh bezahlt]: Vorkommen % bleibt offen', v_due; END IF;
  RAISE NOTICE 'PASS loan [3 Tage vor Faelligkeit bezahlt -> Vorkommen geschlossen]';
END $$;

-- WP2 (weniger Rueckfragen): ohne Betrag bucht die fn die faellige Rate (Betrag des naechstgelegenen offenen Vorkommens);
-- der Return nennt sie (payment_amount). Ohne Raten-Kette -> ok:false (Betrag nennen).
DO $$
DECLARE v_res JSONB; v_giro INT; v_loan INT; v_lacc INT; v_fam JSONB; v_due DATE := CURRENT_DATE - 2;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_blp_def_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_res := finance.fn_create_loan(jsonb_build_object('name','__test_blp_def__','lender','B','original_amount',12000,
    'disbursement_date',(v_due - 30)::text,'interest_rate',6,'monthly_annuity',600,'first_payment_date',v_due::text,'debit_account_id',v_giro));
  v_loan := (v_res->>'loan_id')::int; v_lacc := (v_res->>'loan_account_id')::int;
  v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_giro));
  -- 12.000 x 6 % / 12 = 60 Zins, 540 Tilgung
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'payment_amount')::numeric IS DISTINCT FROM 600
     OR (v_res->>'interest_portion')::numeric IS DISTINCT FROM 60.00 OR (v_res->>'matched_due_date')::date IS DISTINCT FROM v_due
     OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -11460.00 THEN
    RAISE EXCEPTION 'FAIL loan [ohne Betrag]: faellige Rate 600 erwartet, got %', v_res; END IF;
  v_fam := finance.fn_create_loan(jsonb_build_object('name','__test_blp_fam__','lender','Familie','current_balance',2000,
    'interest_rate',0,'debit_account_id',v_giro));
  v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',(v_fam->>'loan_id')::int,
    'loan_account_id',(v_fam->>'loan_account_id')::int,'debit_account_id',v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL loan [ohne Betrag, ohne Rate]: ok:false erwartet, got %', v_res; END IF;
  RAISE NOTICE 'PASS loan [ohne Betrag -> faellige Rate 600 (60/540) gebucht; ohne Raten-Kette ok:false]';
END $$;
-- Review WP2: ohne Betrag, aber mit explizitem (altem) Faelligkeitstermin ausserhalb des 90-Tage-Fensters -> dessen Rate
DO $$
DECLARE v_res JSONB; v_giro INT; v_loan INT; v_lacc INT; v_due DATE := (date_trunc('month', CURRENT_DATE) - interval '5 months')::date;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_blp_old_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_res := finance.fn_create_loan(jsonb_build_object('name','__test_blp_old__','lender','B','original_amount',12000,
    'disbursement_date',(v_due - 30)::text,'interest_rate',6,'monthly_annuity',600,'first_payment_date',v_due::text,'debit_account_id',v_giro));
  v_loan := (v_res->>'loan_id')::int; v_lacc := (v_res->>'loan_account_id')::int;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'due_date',v_due::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'payment_amount')::numeric IS DISTINCT FROM 600 THEN
    RAISE EXCEPTION 'FAIL loan [ohne Betrag, alter Termin]: got %', v_res; END IF;
  RAISE NOTICE 'PASS loan [ohne Betrag + expliziter alter Termin -> dessen Rate 600]';
END $$;
ROLLBACK;
