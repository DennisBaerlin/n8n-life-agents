-- tests/db/finance/test_fn_book_recurring_occurrence.sql
-- Testet das Buchen eines Recurring-Vorkommens: Transaktion (signed amount, Datum, Link,
-- category=other) + Saldo via Trigger; Idempotenz-Guard.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_rp     INT;
  v_tx     INT;
  v_due    DATE := '2026-05-01';
  v_bal    NUMERIC;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_bookrec_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- Ausgabe 200 (signed -200) monatlich
  v_rp := finance.fn_add_recurring_payment(v_acct, -200, 'Miete', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                         '2026-05-01', '2026-05-01', NULL, NULL, NULL);

  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [book]: erwartet ok=true, got %', v_result;
  END IF;
  v_tx := (v_result->>'transaction_id')::int;

  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_tx AND account_id = v_acct AND amount = -200 AND transaction_date = v_due
      AND category = 'other' AND recurring_payment_id = v_rp
  ) THEN
    RAISE EXCEPTION 'FAIL [book]: Transaktions-Felder nicht korrekt (tx=%)', v_tx;
  END IF;
  RAISE NOTICE 'PASS [book]: tx=% korrekt verknuepft', v_tx;

  -- Saldo via Trigger = -200
  SELECT finance.fn_get_balance(v_acct) INTO v_bal;
  IF v_bal IS DISTINCT FROM -200 THEN
    RAISE EXCEPTION 'FAIL [book balance]: erwartet -200, got %', v_bal;
  END IF;
  RAISE NOTICE 'PASS [book balance] = %', v_bal;

  -- Idempotenz: doppelt buchen -> {ok:false}, kein zweiter Tx
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'code' IS DISTINCT FROM 'already_booked' THEN
    RAISE EXCEPTION 'FAIL [double book]: erwartet ok=false + code=already_booked, got %', v_result;
  END IF;
  IF (SELECT count(*) FROM finance.transactions WHERE recurring_payment_id = v_rp AND transaction_date = v_due) <> 1 THEN
    RAISE EXCEPTION 'FAIL [double book]: zweiter Tx wurde gebucht';
  END IF;
  RAISE NOTICE 'PASS [double book -> ok:false, kein 2. Tx]';

END $$;

-- ============================================================
-- WS-5c-A: optionaler amount (Betrags-Anpassung am Stichtag)
--   sign(rp.amount)*abs(amount) -> Richtung Einnahme/Ausgabe bleibt;
--   amount<=0 -> {ok:false} ohne Write; Transfer + amount -> zwei Beine mit dem Ist-Betrag (Monats-Check WP-A:
--   der Kontoauszug kennt den echten Betrag einer Sparrate; vorher {ok:false}).
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_acct2  INT;
  v_rp     INT;
  v_rpt    INT;
  v_due    DATE := '2026-05-01';
  v_bal    NUMERIC;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_bookrec_adj__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- (1) Ausgabe (signed -200): mit amount=180 -> bucht -180 (Vorzeichen bleibt negativ)
  v_rp := finance.fn_add_recurring_payment(v_acct, -200, 'Strom', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                           '2026-05-01', '2026-05-01', NULL, NULL, NULL);
  SELECT finance.fn_book_recurring_occurrence(
    jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due, 'amount', 180)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [adjust expense]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions
                 WHERE id = (v_result->>'transaction_id')::int AND amount = -180 AND recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [adjust expense]: erwartet Tx amount=-180';
  END IF;
  RAISE NOTICE 'PASS [adjust expense -> -180]';

  -- (2) Einnahme (signed +3000): mit amount=2800 -> bucht +2800
  v_rp := finance.fn_add_recurring_payment(v_acct, 3000, 'Gehalt', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                           '2026-05-01', '2026-05-01', NULL, NULL, NULL);
  SELECT finance.fn_book_recurring_occurrence(
    jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due, 'amount', 2800)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [adjust income]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions
                 WHERE id = (v_result->>'transaction_id')::int AND amount = 2800 AND recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [adjust income]: erwartet Tx amount=+2800';
  END IF;
  RAISE NOTICE 'PASS [adjust income -> +2800]';

  -- (3) amount<=0 -> {ok:false}, kein Write
  v_rp := finance.fn_add_recurring_payment(v_acct, -50, 'Nullfall', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                           '2026-06-01', '2026-06-01', NULL, NULL, NULL);
  SELECT finance.fn_book_recurring_occurrence(
    jsonb_build_object('recurring_payment_id', v_rp, 'due_date', '2026-06-01'::date, 'amount', 0)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [amount=0]: erwartet ok=false, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [amount=0]: kein Write erwartet';
  END IF;
  RAISE NOTICE 'PASS [amount=0 -> ok:false, kein Write]';

  -- (4) Transfer + amount -> zwei Beine mit dem Ist-Betrag (Monats-Check WP-A)
  SELECT finance.fn_create_account(
    '{"name":"__test_bookrec_adj2__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct2 := (v_result->>'account_id')::int;
  v_rpt := finance.fn_add_recurring_payment(v_acct, -100, 'Transfer', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                            '2026-07-01', '2026-07-01', NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_acct2 WHERE id = v_rpt;
  SELECT finance.fn_book_recurring_occurrence(
    jsonb_build_object('recurring_payment_id', v_rpt, 'due_date', '2026-07-01'::date, 'amount', 90)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [transfer+amount]: erwartet ok=true, got %', v_result;
  END IF;
  IF (SELECT amount FROM finance.transactions WHERE id = (v_result->>'debit_tx_id')::int) IS DISTINCT FROM -90.00
     OR (SELECT amount FROM finance.transactions WHERE id = (v_result->>'credit_tx_id')::int) IS DISTINCT FROM 90.00 THEN
    RAISE EXCEPTION 'FAIL [transfer+amount]: erwartet Beine -90/+90, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [transfer+amount -> zwei Beine -90/+90]';

END $$;

-- (5) Audit F1a: Kreditrate ueber die Erinnerung -> Delegation an fn_book_loan_payment (Giro-Abbuchung + Tilgung).
--     Vorher: eine nackte 'other'-Abbuchung, die Restschuld blieb stehen (200.000 statt 199.600: Rate 1.000 = Zins 600 + Tilgung 400).
DO $$
DECLARE
  v_res  JSONB; v_giro INT; v_loan INT; v_lacc INT; v_rp INT;
  v_due  DATE := CURRENT_DATE - 10;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_bookrec_lgiro__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_bookrec_kredit__','lender','B','borrower','T',
    'original_amount',200000,'current_balance',200000,'disbursement_date',(v_due - 30)::text,'interest_rate',3.6,
    'monthly_annuity',1000,'first_payment_date',v_due::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;

  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [loan-delegation]: %', v_res; END IF;
  IF finance.fn_get_balance(v_lacc) IS DISTINCT FROM -199600.00 OR finance.fn_get_balance(v_giro) IS DISTINCT FROM -1000.00 THEN
    RAISE EXCEPTION 'FAIL [loan-delegation]: Kreditkonto=% Giro=% (erwartet -199600/-1000)',
      finance.fn_get_balance(v_lacc), finance.fn_get_balance(v_giro); END IF;
  -- normalisierte Rueckgabe: transaction_id = Giro-Bein (category loan_payment, rp gestempelt) + Kredit-Post-State
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = (v_res->>'transaction_id')::int
                 AND category = 'loan_payment' AND recurring_payment_id = v_rp AND transaction_date = v_due) THEN
    RAISE EXCEPTION 'FAIL [loan-delegation return]: transaction_id ist nicht das gestempelte Giro-Bein, got %', v_res; END IF;
  IF (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 199600
     OR (v_res->>'interest_portion')::numeric IS DISTINCT FROM 600
     OR (v_res->>'principal_amount')::numeric IS DISTINCT FROM 400
     OR (v_res->>'amount')::numeric IS DISTINCT FROM -1000 THEN
    RAISE EXCEPTION 'FAIL [loan-delegation return]: erwartet remaining 199600 / Zins 600 / Tilgung 400 / amount -1000, got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_rp AND due_date = v_due) THEN
    RAISE EXCEPTION 'FAIL [loan-delegation]: Vorkommen nach Buchung noch offen'; END IF;
  RAISE NOTICE 'PASS [Kreditrate ueber Erinnerung -> Tilgung gebucht, Restschuld 199600]';

  -- Doppelt -> ok:false, keine zweite Tilgung
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -199600.00 THEN
    RAISE EXCEPTION 'FAIL [loan-delegation doppelt]: %, Kreditkonto=%', v_res, finance.fn_get_balance(v_lacc); END IF;
  RAISE NOTICE 'PASS [Kreditrate doppelt -> ok:false]';
END $$;

ROLLBACK;
