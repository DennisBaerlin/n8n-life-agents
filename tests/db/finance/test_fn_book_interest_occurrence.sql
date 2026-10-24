-- tests/db/finance/test_fn_book_interest_occurrence.sql
-- Bucht eine Zinsgutschrift: transaction_date=value_date, interest_period_end=period_end (Idempotenz-/booked-Key);
-- Betrag DB-berechnet (fn_interest_amount_due am period_end) ODER Override; amount<=0 -> {ok:false}.
-- Inkl. Arrears-Zinseszins ueber 2 Perioden in EINEM Backfill (period_end ASC -> Periode 2 sieht die Gutschrift 1).
BEGIN;

DO $$
DECLARE
  v_res  JSONB;
  v_acct INT;
  v_tx   INT;
BEGIN
  -- ===== Buchen OHNE Override: DB-berechnet (4% jaehrlich, 10000, period_end = echtes Jahres-Ende) =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_book__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"year","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');

  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2027-01-01', 'period_end', '2027-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [book computed]: %', v_res; END IF;
  IF (v_res->>'amount')::numeric IS DISTINCT FROM 400.00 THEN RAISE EXCEPTION 'FAIL [book computed]: erwartet 400.00, got %', v_res->>'amount'; END IF;
  v_tx := (v_res->>'transaction_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions
                 WHERE id = v_tx AND category = 'interest' AND transaction_date = '2027-01-01'
                   AND interest_period_end = '2027-01-01' AND amount = 400.00) THEN
    RAISE EXCEPTION 'FAIL [book computed]: Zins-Tx (transaction_date/interest_period_end) nicht korrekt';
  END IF;
  IF (v_res->>'account_balance')::numeric IS DISTINCT FROM 10400.00 THEN RAISE EXCEPTION 'FAIL [book computed]: Saldo 10400 erwartet, got %', v_res->>'account_balance'; END IF;
  RAISE NOTICE 'PASS [book computed -> 400.00, Saldo 10400]';

  -- ===== Idempotenz auf period_end: zweite Buchung fuer dieselbe Periode (auch anderes value_date) -> {ok:false} =====
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2027-02-05', 'period_end', '2027-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'code' IS DISTINCT FROM 'already_booked' THEN
    RAISE EXCEPTION 'FAIL [idempotent]: erwartet ok=false + code=already_booked, got %', v_res; END IF;
  IF (SELECT count(*) FROM finance.transactions
      WHERE account_id = v_acct AND category = 'interest' AND interest_period_end = '2027-01-01') <> 1 THEN
    RAISE EXCEPTION 'FAIL [idempotent]: zweite Zins-Tx gebucht';
  END IF;
  RAISE NOTICE 'PASS [idempotent auf period_end -> ok:false, kein 2. Tx]';

  -- ===== Arrears: value_date <> period_end (Gutschrift im Folgemonat, deckt Vorperiode) =====
  SELECT finance.fn_create_account(
    '{"name":"__test_int_arrears_book__","account_type":"cash","currency":"EUR","interest_rate":4,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 12000, '2026-01-01', 'other');
  -- period_end 2026-02-01 (Jan-Periode), value_date 2026-02-05 (arrears). 12000*4%*1/12 = 40.00
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-02-05', 'period_end', '2026-02-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'amount')::numeric IS DISTINCT FROM 40.00 THEN
    RAISE EXCEPTION 'FAIL [arrears book]: erwartet ok=true amount=40.00, got %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (v_res->>'transaction_id')::int
                 AND transaction_date = '2026-02-05' AND interest_period_end = '2026-02-01') THEN
    RAISE EXCEPTION 'FAIL [arrears book]: transaction_date(value_date)=2026-02-05, interest_period_end=2026-02-01 erwartet';
  END IF;
  RAISE NOTICE 'PASS [arrears: value_date 2026-02-05 entkoppelt von period_end 2026-02-01]';

  -- ===== Override: anderer period_end, Nutzer-Ist 12.50 =====
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-03-01', 'period_end', '2026-03-01', 'amount', 12.50)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'amount')::numeric IS DISTINCT FROM 12.50 THEN
    RAISE EXCEPTION 'FAIL [override]: erwartet ok=true amount=12.50, got %', v_res; END IF;
  RAISE NOTICE 'PASS [override -> 12.50]';

  -- ===== amount<=0 (Override 0) -> {ok:false}, kein Write =====
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-04-01', 'period_end', '2026-04-01', 'amount', 0)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [amount=0]: erwartet ok=false, got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions
             WHERE account_id = v_acct AND category = 'interest' AND interest_period_end = '2026-04-01') THEN
    RAISE EXCEPTION 'FAIL [amount=0]: kein Write erwartet';
  END IF;
  RAISE NOTICE 'PASS [amount=0 -> ok:false, kein Write]';

  -- ===== Arrears-Zinseszins ueber 2 Perioden in EINEM Backfill (B2) =====
  -- 12% monatlich auf 10000, 30E/360, Arrears (value_date im Folgemonat). period_end ASC gebucht ->
  -- Periode 2 sieht die Gutschrift aus Periode 1 (transaction_date <= period_end_2), kompoundiert.
  SELECT finance.fn_create_account(
    '{"name":"__test_int_backfill__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_acct, 10000, '2026-01-01', 'other');

  -- Periode 1: period_end 2026-02-01, value_date 2026-02-05 -> 10000*12%*1/12 = 100.00
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-02-05', 'period_end', '2026-02-01')) INTO v_res;
  IF (v_res->>'amount')::numeric IS DISTINCT FROM 100.00 THEN RAISE EXCEPTION 'FAIL [backfill p1]: erwartet 100.00, got %', v_res->>'amount'; END IF;

  -- Periode 2: period_end 2026-03-01, value_date 2026-03-05 -> basis 10100 (Gutschrift 1 zaehlt) -> 101.00
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'value_date', '2026-03-05', 'period_end', '2026-03-01')) INTO v_res;
  IF (v_res->>'amount')::numeric IS DISTINCT FROM 101.00 THEN RAISE EXCEPTION 'FAIL [backfill p2 compound]: erwartet 101.00, got %', v_res->>'amount'; END IF;
  RAISE NOTICE 'PASS [Arrears-Zinseszins 2 Perioden im Backfill: 100.00 -> 101.00]';

  -- ===== WS-Z4: Buchung auf einen nicht-zins-faehigen Kontotyp (Kredit) -> {ok:false}, kein Write =====
  -- (schliesst das manuelle Buchungs-Loch; der Eligibility-Guard greift VOR der Betragsberechnung)
  -- loan-Konto direkt (fn_create_account lehnt loan ab; Kredit-Konten legt nur fn_create_loan an)
  WITH i AS (INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test_int_loan_book__', 'loan', 'EUR') RETURNING id)
    SELECT jsonb_build_object('account_id', id) INTO v_res FROM i;
  v_acct := (v_res->>'account_id')::int;
  SELECT finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_acct, 'period_end', '2026-02-01', 'amount', 50)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [loan ineligible]: erwartet ok=false, got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_acct AND category = 'interest') THEN
    RAISE EXCEPTION 'FAIL [loan ineligible]: kein Zins-Write auf ein Kredit-Konto erwartet';
  END IF;
  RAISE NOTICE 'PASS [Kredit nicht zins-faehig -> book ok:false, kein Write]';

END $$;

ROLLBACK;
