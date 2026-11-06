-- tests/db/finance/test_fn_delete_loan.sql
-- Testet fn_delete_loan: Hard-DELETE (Fehlanlage ohne Raten; Inverse von create_loan),
-- Resolution auch paused-Kredite, Guard (gebuchte Rate), not-found.
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_debit   INT;
  v_loan    INT;
  v_loanacc INT;
  v_rp      INT;
  v_paused  INT;
  v_paccc   INT;
  v_with    INT;
  v_wacc    INT;
  v_cnt     INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_dl_debit__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_debit;

  -- Kredit A: aktiv, mit Annuitaet (=> rp), keine Raten gebucht -> loeschbar
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_dl_active__','lender','TB','borrower','T','original_amount','10000','current_balance','10000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','500',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit)) INTO v_res;
  v_loan    := (v_res->>'loan_id')::int;
  v_loanacc := (v_res->>'loan_account_id')::int;
  v_rp      := (v_res->>'recurring_payment_id')::int;

  -- Kredit B: paused (keine Annuitaet) -> Resolution mit p_active_only=FALSE muss greifen
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_dl_paused__','lender','TB','borrower','T','original_amount','5000','current_balance','5000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','debit_account_id',v_debit)) INTO v_res;
  v_paused := (v_res->>'loan_id')::int;
  v_paccc  := (v_res->>'loan_account_id')::int;

  -- Kredit C: aktiv + gebuchte Rate -> Guard
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_dl_with__','lender','TB','borrower','T','original_amount','10000','current_balance','10000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','500',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit)) INTO v_res;
  v_with := (v_res->>'loan_id')::int;
  v_wacc := (v_res->>'loan_account_id')::int;
  PERFORM finance.fn_book_loan_payment(jsonb_build_object(
    'loan_id',v_with,'loan_account_id',v_wacc,'debit_account_id',v_debit,
    'payment_amount','500','payment_date',CURRENT_DATE::text));

  -- TEST 1: Hard-DELETE aktiver Fehlanlage (Loan + Loan-Konto + rp + Disbursement-Beine weg)
  SELECT finance.fn_delete_loan('{"loan_name":"__test_dl_active__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL delete_loan [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.loans WHERE id = v_loan;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_loan [loan noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_loanacc;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_loan [loan-konto noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_loan [rp noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.transactions WHERE loan_id = v_loan;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_loan [disbursement-tx noch da]'; END IF;
  -- Giro unangetastet (kein disbursement_account -> keine Buchung; muss existieren)
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_debit;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_loan [Giro faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_loan [Hard-DELETE: Loan+Konto+rp+Tx weg, Giro bleibt]';

  -- TEST 2: paused-Kredit loeschbar (Resolution p_active_only=FALSE)
  SELECT finance.fn_delete_loan('{"loan_name":"__test_dl_paused__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL delete_loan [paused]: erwartet ok=true, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_paccc;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_loan [paused loan-konto noch da]'; END IF;
  RAISE NOTICE 'PASS delete_loan [paused-Kredit geloescht]';

  -- TEST 3: Guard gebuchte Rate -> {ok:false}, Kredit bleibt
  SELECT finance.fn_delete_loan('{"loan_name":"__test_dl_with__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete_loan [repay-guard]: erwartet ok=false, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.loans WHERE id = v_with;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_loan [Kredit C faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_loan [repay-guard: ok=false, Kredit bleibt]';

  -- TEST 4: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_delete_loan('{"loan_name":"__test_dl_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL delete_loan [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS delete_loan [not-found -> ok:false]';
END $$;

ROLLBACK;
