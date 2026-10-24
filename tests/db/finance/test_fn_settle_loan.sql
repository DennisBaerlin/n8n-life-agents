-- tests/db/finance/test_fn_settle_loan.sql
-- Testet fn_settle_loan: Abloesung (Restschuld -> 0, status=paid_off, Rate beendet),
-- Abloesung mit Zinsanteil, Guards (Betrag < Restschuld / keine Restschuld), 2-Bein group_id.
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_debit   INT;
  v_loan    INT;
  v_loanacc INT;
  v_rp      INT;
  v_loan2   INT; v_lacc2 INT;
  v_loan3   INT; v_lacc3 INT;
  v_giro    NUMERIC;
  v_lbal    NUMERIC;
  v_status  TEXT;
  v_rpstat  TEXT;
  v_rpvalid DATE;
  v_grp     UUID;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_sl_debit__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_debit;

  -- Kredit 1: Restschuld 10000
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_full__','lender','TB','borrower','T','original_amount','10000','current_balance','10000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','500',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int; v_loanacc := (v_res->>'loan_account_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;

  -- TEST 1: Abloesung mit Default-Betrag (= Restschuld) -> Loan-Saldo 0, paid_off, Rate beendet
  SELECT finance.fn_settle_loan(jsonb_build_object(
    'loan_name','__test_sl_full__','debit_account_id',v_debit,'settlement_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL settle_loan [full]: erwartet ok=true, got %', v_res; END IF;
  IF (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 10000 THEN
    RAISE EXCEPTION 'FAIL settle_loan [remaining_debt]: erwartet 10000, got %', v_res->>'remaining_debt'; END IF;
  SELECT finance.fn_get_balance(v_loanacc) INTO v_lbal;
  IF v_lbal IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL settle_loan [loan-bal]: erwartet 0, got %', v_lbal; END IF;
  SELECT finance.fn_get_balance(v_debit) INTO v_giro;
  IF v_giro IS DISTINCT FROM -10000 THEN RAISE EXCEPTION 'FAIL settle_loan [giro-bal]: erwartet -10000, got %', v_giro; END IF;
  SELECT status::text INTO v_status FROM finance.loans WHERE id = v_loan;
  IF v_status IS DISTINCT FROM 'paid_off' THEN RAISE EXCEPTION 'FAIL settle_loan [status]: erwartet paid_off, got %', v_status; END IF;
  SELECT status::text, valid_to INTO v_rpstat, v_rpvalid FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpstat IS DISTINCT FROM 'paused' OR v_rpvalid IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL settle_loan [rate-beendet]: erwartet paused + valid_to=heute, got %/%', v_rpstat, v_rpvalid; END IF;
  -- beide Beine teilen eine group_id
  SELECT group_id INTO v_grp FROM finance.transactions WHERE id = (v_res->>'settlement_tx_id')::int;
  SELECT COUNT(*) INTO v_status FROM finance.transactions WHERE group_id = v_grp;
  IF v_status::int <> 2 THEN RAISE EXCEPTION 'FAIL settle_loan [group_id]: erwartet 2 Beine, got %', v_status; END IF;
  RAISE NOTICE 'PASS settle_loan [full: Saldo 0, paid_off, Rate beendet, group_id]';

  -- TEST 2: Abloesung mit Zinsanteil (Betrag > Restschuld)
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_interest__','lender','TB','borrower','T','original_amount','10000','current_balance','10000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','500',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit)) INTO v_res;
  v_loan2 := (v_res->>'loan_id')::int; v_lacc2 := (v_res->>'loan_account_id')::int;
  SELECT finance.fn_settle_loan(jsonb_build_object(
    'loan_name','__test_sl_interest__','debit_account_id',v_debit,'settlement_amount','10100','settlement_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'interest')::numeric IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL settle_loan [interest]: erwartet ok=true interest=100, got %', v_res; END IF;
  SELECT finance.fn_get_balance(v_lacc2) INTO v_lbal;
  IF v_lbal IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL settle_loan [interest loan-bal]: erwartet 0, got %', v_lbal; END IF;
  RAISE NOTICE 'PASS settle_loan [interest: interest=100, Saldo 0]';

  -- TEST 3: Betrag < Restschuld -> {ok:false}
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sl_under__','lender','TB','borrower','T','original_amount','10000','current_balance','10000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','500',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit)) INTO v_res;
  v_loan3 := (v_res->>'loan_id')::int; v_lacc3 := (v_res->>'loan_account_id')::int;
  SELECT finance.fn_settle_loan(jsonb_build_object(
    'loan_name','__test_sl_under__','debit_account_id',v_debit,'settlement_amount','5000','settlement_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL settle_loan [under]: erwartet ok=false, got %', v_res; END IF;
  SELECT finance.fn_get_balance(v_lacc3) INTO v_lbal;
  IF v_lbal IS DISTINCT FROM -10000 THEN RAISE EXCEPTION 'FAIL settle_loan [under: Saldo veraendert]'; END IF;
  RAISE NOTICE 'PASS settle_loan [under: ok=false, nichts gebucht]';

  -- TEST 4: keine Restschuld (manuell auf 0 getilgt) -> {ok:false}
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
  VALUES (v_lacc3, 10000, CURRENT_DATE, 'principal', v_loan3);  -- Saldo -> 0, Kredit bleibt aktiv
  SELECT finance.fn_settle_loan(jsonb_build_object(
    'loan_name','__test_sl_under__','debit_account_id',v_debit,'settlement_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL settle_loan [no-debt]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS settle_loan [no-debt: ok=false]';

  -- TEST 5: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_settle_loan(jsonb_build_object('loan_name','__test_sl_missing__','debit_account_id',v_debit,'settlement_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL settle_loan [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS settle_loan [not-found -> ok:false]';
END $$;

ROLLBACK;
