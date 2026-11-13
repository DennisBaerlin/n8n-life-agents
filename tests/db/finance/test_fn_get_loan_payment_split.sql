-- tests/db/finance/test_fn_get_loan_payment_split.sql
-- Testet fn_get_loan_payment_split: die eine Zins/Tilgungs-Formel fuer HITL-Vorschau und Buchung.
--   Read-only (kein Write), dieselben Zahlen wie fn_book_loan_payment, korrigierbare Faelle als {ok:false}.
--   Die Restschuld wird positiv gefuehrt; mit der negativen Restschuld ergaebe sich Zins negativ / Tilgung zu gross.
BEGIN;

-- Tilgung > Rate / negativ -> {ok:false}; reine Zinsrate bucht nur das Giro-Bein (ein 0-EUR-Tilgungsbein loeste
-- den CHECK aus); Quartalsrate traegt drei Monatszinsen.
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

-- Rate 0 bei einem zinslosen Kredit: ohne die Positiv-Pruefung waere Zins 0 = Tilgung 0 ein gueltiger Split.
DO $$
DECLARE
  v_res  JSONB;
  v_giro INT;
  v_loan INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_lps0_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__test_lps0_kredit__','lender','B','borrower','T',
    'original_amount',1200,'current_balance',1200,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',0,
    'monthly_annuity',100,'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_giro))->>'loan_id')::int
    INTO v_loan;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',0,
    'principal_amount',0));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL split [Rate 0, 0 %%]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS split [Rate 0 bei 0 %% -> ok:false]';
END $$;

-- Raten-Abgleich auf Cent: eine Zahlung mit Bruchteil-Cent trifft die faellige Rate trotzdem.
DO $$
DECLARE
  v_res  JSONB;
  v_giro INT;
  v_loan INT;
  v_due  DATE := CURRENT_DATE - 3;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_lpsc_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__test_lpsc_kredit__','lender','B','borrower','T',
    'original_amount',6000,'current_balance',6000,'disbursement_date',(v_due - 30)::text,'interest_rate',2,
    'monthly_annuity',300,'first_payment_date',v_due::text,'debit_account_id',v_giro))->>'loan_id')::int INTO v_loan;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',300.004,
    'payment_date',CURRENT_DATE::text));
  IF (v_res->>'matched_due_date')::date IS DISTINCT FROM v_due THEN
    RAISE EXCEPTION 'FAIL split [Bruchteil-Cent]: erwartet faellig %, got %', v_due, v_res; END IF;
  RAISE NOTICE 'PASS split [Rate 300.004 trifft die Rate 300]';
END $$;

-- Zwei offene Raten im Fenster: die zeitlich naechste gewinnt, nicht die aelteste.
DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_loan  INT;
  v_first DATE := CURRENT_DATE - 25;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_lpsn_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__test_lpsn_kredit__','lender','B','borrower','T',
    'original_amount',6000,'current_balance',6000,'disbursement_date',(v_first - 15)::text,'interest_rate',2,
    'monthly_annuity',300,'first_payment_date',v_first::text,'debit_account_id',v_giro))->>'loan_id')::int INTO v_loan;
  v_res := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',300,
    'payment_date',CURRENT_DATE::text));
  IF (v_res->>'matched_due_date')::date IS DISTINCT FROM (v_first + interval '1 month')::date THEN
    RAISE EXCEPTION 'FAIL split [naechste Rate]: erwartet %, got %', (v_first + interval '1 month')::date, v_res; END IF;
  RAISE NOTICE 'PASS split [naechste offene Rate gewinnt]';
END $$;

-- Sondertilgung nach gebuchter Rate: der Zins der Periode ist mit der Rate bezahlt -> die Zusatzzahlung ohne
-- principal_amount ist reine Tilgung (100.000 zu 3 %, Rate 800 heute gebucht, dann 5.000 extra: Zins 0, Tilgung 5.000).
DO $$
DECLARE
  v_giro int; v_la int; v_rp int; v_l int; r jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__lpsx_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__lpsx_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__lpsx_rate__', v_giro, -800, 'month', current_date - 2, current_date - 2) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__lpsx_kredit__', 3.0, 'active', v_la, v_giro, v_rp) RETURNING id INTO v_l;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id) VALUES (v_la, -100000, current_date - 40, 'disbursement', v_l);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 20000, current_date - 40, 'other');
  r := finance.fn_book_loan_payment(jsonb_build_object('loan_id', v_l, 'loan_account_id', v_la, 'debit_account_id', v_giro,
                                                      'payment_amount', 800, 'payment_date', current_date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'remaining_debt')::numeric IS DISTINCT FROM 99450.00 OR r->>'matched_due_date' IS NULL THEN
    RAISE EXCEPTION 'SETUP split [regulaere Rate]: %', r; END IF;
  r := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l, 'payment_amount', 5000, 'payment_date', current_date::text));
  IF (r->>'principal_amount')::numeric IS DISTINCT FROM 5000.00 OR (r->>'interest_portion')::numeric IS DISTINCT FROM 0
     OR r->>'matched_due_date' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL split [Sondertilgung nach gebuchter Rate: Zins 0, Tilgung 5000]: %', r; END IF;
  RAISE NOTICE 'PASS split [Sondertilgung nach gebuchter Rate ist reine Tilgung]';
END $$;

ROLLBACK;
