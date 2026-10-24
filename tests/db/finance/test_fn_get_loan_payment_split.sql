-- tests/db/finance/test_fn_get_loan_payment_split.sql
-- Testet fn_get_loan_payment_split (Audit F1c/F7): die EINE Zins/Tilgungs-Formel fuer HITL-Vorschau UND Buchung.
--   Read-only (kein Write), dieselben Zahlen wie fn_book_loan_payment, korrigierbare Faelle als {ok:false}.
--   Vorher rechnete der Tool-Graph selbst mit der NEGATIVEN Restschuld -> Karte "Zins -600 / Tilgung 1.600".
BEGIN;

-- Audit Paket 2, Punkt 9: Tilgung > Rate / negativ -> {ok:false}; reine Zinsrate bucht nur das Giro-Bein (vorher
-- CHECK-Alarm durch ein 0-EUR-Tilgungsbein); Quartalsrate traegt drei Monatszinsen (vorher einen).
DO $$
DECLARE
  v_res  JSONB;
  v_giro INT;
  v_loan INT;
  v_lacc INT;
  v_rp   INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_lps2_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_lps2_kredit__','lender','B','borrower','T',
    'original_amount',1000,'current_balance',1000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',12,
    'monthly_annuity',100,'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;

  -- Tilgung 600 > Rate 500 -> ok:false (Zins waere -100); Tilgung negativ -> ok:false
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',500,'principal_amount',600));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL split [Tilgung > Rate]: %', v_res; END IF;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',500,'principal_amount',-1));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL split [Tilgung < 0]: %', v_res; END IF;
  RAISE NOTICE 'PASS split [Tilgung > Rate / < 0 -> ok:false]';

  -- reine Zinsrate: Restschuld 1000, 12 % -> Monatszins 10, Rate 10 -> nur Giro-Bein, kein Tilgungsbein
  v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,
    'debit_account_id',v_giro,'payment_amount',10,'payment_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'principal_tx_id' IS NOT NULL
     OR (v_res->>'interest_portion')::numeric IS DISTINCT FROM 10 OR (v_res->>'principal_amount')::numeric IS DISTINCT FROM 0
     OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -1000.00 OR finance.fn_get_balance(v_giro) IS DISTINCT FROM -10.00
     OR v_res->>'loan_status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL book [reine Zinsrate]: % (Kredit %, Giro %)', v_res, finance.fn_get_balance(v_lacc), finance.fn_get_balance(v_giro); END IF;
  RAISE NOTICE 'PASS book [reine Zinsrate: nur Giro-Bein 10, Restschuld unveraendert]';

  -- Quartalsrate: Kadenz der Kredit-rp alle 3 Monate -> Zins 1000 x 12 % / 12 x 3 = 30
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;
  UPDATE finance.recurring_payments SET schedule_interval = 3 WHERE id = v_rp;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',300));
  IF (v_res->>'interest_portion')::numeric IS DISTINCT FROM 30 OR (v_res->>'principal_amount')::numeric IS DISTINCT FROM 270 THEN
    RAISE EXCEPTION 'FAIL split [Quartal]: erwartet Zins 30 / Tilgung 270, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Quartalsrate: Zins 30 = 3 Monatszinsen]';
END $$;

DO $$
DECLARE
  v_res   JSONB;
  v_book  JSONB;
  v_giro  INT;
  v_loan  INT;
  v_lacc  INT;
  v_due   DATE := CURRENT_DATE - 5;
  v_cnt0  INT;
  v_cnt1  INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_lps_giro__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_lps_kredit__','lender','B','borrower','T',
    'original_amount',10000,'current_balance',10000,'disbursement_date',(v_due - 30)::text,'interest_rate',3,
    'monthly_annuity',500,'first_payment_date',v_due::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;

  -- TEST 1: Vorschau = positive Zahlen aus der positiven Restschuld + gematchtes Vorkommen, kein Write
  SELECT count(*) INTO v_cnt0 FROM finance.transactions;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',500,
    'payment_date',CURRENT_DATE::text));
  SELECT count(*) INTO v_cnt1 FROM finance.transactions;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 10000
     OR (v_res->>'interest_portion')::numeric IS DISTINCT FROM 25
     OR (v_res->>'principal_amount')::numeric IS DISTINCT FROM 475
     OR (v_res->>'matched_due_date')::date IS DISTINCT FROM v_due
     OR (v_res->>'booking_date')::date IS DISTINCT FROM v_due THEN
    RAISE EXCEPTION 'FAIL split [Vorschau]: erwartet Rest 10000 / Zins 25 / Tilgung 475 / due % / booking %, got %', v_due, v_due, v_res; END IF;
  IF v_cnt1 <> v_cnt0 THEN RAISE EXCEPTION 'FAIL split [read-only]: % Zeilen geschrieben', v_cnt1 - v_cnt0; END IF;
  RAISE NOTICE 'PASS split [Vorschau: Zins 25, Tilgung 475, faellig %; kein Write]', v_due;

  -- TEST 2: die Buchung liefert exakt dieselben Zahlen (eine Formel)
  v_book := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,
    'debit_account_id',v_giro,'payment_amount',500,'payment_date',CURRENT_DATE::text));
  IF (v_book->>'interest_portion')::numeric IS DISTINCT FROM (v_res->>'interest_portion')::numeric
     OR (v_book->>'principal_amount')::numeric IS DISTINCT FROM (v_res->>'principal_amount')::numeric
     OR (v_book->>'matched_due_date')::date IS DISTINCT FROM (v_res->>'matched_due_date')::date THEN
    RAISE EXCEPTION 'FAIL split [= Buchung]: Vorschau % vs Buchung %', v_res, v_book; END IF;
  RAISE NOTICE 'PASS split [Vorschau = Buchung]';

  -- TEST 3: Ueberzahlung -> {ok:false} mit payoff_amount (Restschuld 9525 + Zins 23.81)
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',20000,
    'payment_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'payoff_amount')::numeric IS DISTINCT FROM 9548.81 THEN
    RAISE EXCEPTION 'FAIL split [Ueberzahlung]: erwartet ok=false payoff 9548.81, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Ueberzahlung -> ok:false, payoff 9548.81]';

  -- TEST 4: Tilgung negativ (Rate < Zins) -> {ok:false}
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',10,
    'payment_date',CURRENT_DATE::text,'principal_amount',-50));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL split [Unterzahlung]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Unterzahlung -> ok:false]';
END $$;

ROLLBACK;
