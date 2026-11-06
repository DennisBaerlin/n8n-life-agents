-- tests/db/finance/test_recurring_due_identity.sql
-- Monats-Check WP-A: Identitaet eines Dauerauftrags-Vorkommens = recurring_due_date (Faelligkeit), entkoppelt vom
-- Buchungsdatum (Ist-Datum laut Kontoauszug), + Doppelzaehlungs-Fix gegen den Saldo-Abgleich:
--   (1) Default: rp-Buchung ohne Faelligkeit -> recurring_due_date = transaction_date (Alt-Semantik)
--   (2) Buchung am Ist-Datum (!= Faelligkeit) schliesst das Vorkommen; 2-arg fn_recurring_due_open
--   (3) Buchungsdatum <= last_reconciled_at des Kontos -> {ok:false, code:'reconciled'}, kein Write
--   (4) Transfer mit Ist-Betrag (zwei Beine) + Guard auch auf dem Ziel-Konto
--   (5) fn_reconcile_account materialisiert offene Vorkommen mit due <= Stichtag-10 als Skip
--   (6) Zinsgutschrift mit value_date <= last_reconciled_at -> reconciled
--   (7) Kreditrate mit Ist-Datum: Giro-Bein am Ist-Datum, Identitaet = Faelligkeit
--   (8) Sparplan-Ausfuehrung ueber recurring_payment_id + due_date + transaction_date
--   (9) fn_split_recurring_payment: Stichtag-Guard keyt auf die Faelligkeit, nicht aufs Buchungsdatum
BEGIN;

DO $$
DECLARE
  v_res  JSONB; v_a INT; v_b INT; v_rp INT; v_rpt INT; v_tx INT;
  v_d    DATE := CURRENT_DATE - 40;   -- Faelligkeit
  v_due  DATE; v_date DATE; c INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__t_rdi_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
  SELECT (finance.fn_create_account('{"name":"__t_rdi_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_b;

  -- (1) Default-Identitaet
  v_rp := finance.fn_add_recurring_payment(v_a, -50, 'Default', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                           v_d, v_d, NULL, NULL, NULL);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id)
  VALUES (v_a, -50, v_d + 2, 'other', v_rp) RETURNING id INTO v_tx;
  SELECT recurring_due_date INTO v_due FROM finance.transactions WHERE id = v_tx;
  IF v_due IS DISTINCT FROM v_d + 2 THEN RAISE EXCEPTION 'FAIL (1) default due: erwartet %, got %', v_d + 2, v_due; END IF;
  RAISE NOTICE 'PASS (1) rp-Buchung ohne Faelligkeit -> recurring_due_date = transaction_date';

  -- (2) Ist-Datum != Faelligkeit schliesst das Vorkommen
  v_rp := finance.fn_add_recurring_payment(v_a, -850, 'Miete', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                           v_d, v_d, NULL, NULL, NULL);
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d, 'amount', 900, 'transaction_date', (v_d + 3)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (2) book: %', v_res; END IF;
  SELECT transaction_date, recurring_due_date INTO v_date, v_due FROM finance.transactions WHERE id = (v_res->>'transaction_id')::int;
  IF v_date IS DISTINCT FROM v_d + 3 OR v_due IS DISTINCT FROM v_d THEN
    RAISE EXCEPTION 'FAIL (2) Felder: date=% due=% (erwartet %/%)', v_date, v_due, v_d + 3, v_d; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_rp AND due_date = v_d) THEN
    RAISE EXCEPTION 'FAIL (2): Vorkommen % trotz Buchung am Ist-Datum offen', v_d; END IF;
  -- erneut -> already_booked (Identitaet = Faelligkeit, auch mit anderem Ist-Datum)
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d, 'transaction_date', (v_d + 5)::text));
  IF v_res->>'code' IS DISTINCT FROM 'already_booked' THEN RAISE EXCEPTION 'FAIL (2) doppelt: %', v_res; END IF;
  -- 2-arg: Fenster [von, bis]
  SELECT count(*) INTO c FROM finance.fn_recurring_due_open(v_d + 1, CURRENT_DATE) WHERE recurring_payment_id = v_rp;
  IF c <> 1 THEN RAISE EXCEPTION 'FAIL (2) 2-arg: erwartet 1 offenes Vorkommen nach %, got %', v_d, c; END IF;
  RAISE NOTICE 'PASS (2) Ist-Datum schliesst Vorkommen; doppelt -> already_booked; 2-arg-Fenster';

  -- (3) Guard: Buchungsdatum <= letzter Abgleich
  v_rp := finance.fn_add_recurring_payment(v_a, -30, 'Handy', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                           v_d, v_d, NULL, NULL, NULL);
  UPDATE finance.accounts SET last_reconciled_at = v_d + 10, last_reconciled_balance = 0 WHERE id = v_a;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_d));
  IF v_res->>'code' IS DISTINCT FROM 'reconciled' THEN RAISE EXCEPTION 'FAIL (3) reconciled: %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = v_rp) THEN RAISE EXCEPTION 'FAIL (3): Write trotz Guard'; END IF;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d, 'transaction_date', (v_d + 11)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (3) nach Abgleich: %', v_res; END IF;
  RAISE NOTICE 'PASS (3) Buchung im schon abgeglichenen Zeitraum -> reconciled; danach ok';
  UPDATE finance.accounts SET last_reconciled_at = NULL, last_reconciled_balance = NULL WHERE id = v_a;

  -- (4) Transfer mit Ist-Betrag + Guard auf dem Ziel-Konto
  v_rpt := finance.fn_add_recurring_payment(v_a, -300, 'Sparrate', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                            v_d, v_d, NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_b WHERE id = v_rpt;
  UPDATE finance.accounts SET last_reconciled_at = v_d + 10, last_reconciled_balance = 0 WHERE id = v_b;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rpt, 'due_date', v_d, 'amount', 250, 'transaction_date', (v_d + 1)::text));
  IF v_res->>'code' IS DISTINCT FROM 'reconciled' THEN RAISE EXCEPTION 'FAIL (4) Ziel-Guard: %', v_res; END IF;
  UPDATE finance.accounts SET last_reconciled_at = NULL, last_reconciled_balance = NULL WHERE id = v_b;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rpt, 'due_date', v_d, 'amount', 250, 'transaction_date', (v_d + 1)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (4) transfer+amount: %', v_res; END IF;
  IF (SELECT amount FROM finance.transactions WHERE id = (v_res->>'debit_tx_id')::int) IS DISTINCT FROM -250.00
     OR (SELECT amount FROM finance.transactions WHERE id = (v_res->>'credit_tx_id')::int) IS DISTINCT FROM 250.00
     OR (SELECT count(*) FROM finance.transactions WHERE recurring_payment_id = v_rpt AND recurring_due_date = v_d AND transaction_date = v_d + 1) <> 2 THEN
    RAISE EXCEPTION 'FAIL (4) Beine: %', v_res; END IF;
  RAISE NOTICE 'PASS (4) Transfer mit Ist-Betrag zwei Beine; Ziel-Konto abgeglichen -> reconciled';
END $$;

-- (5) Saldo-Abgleich schliesst alte offene Vorkommen als Skip
DO $$
DECLARE v_res JSONB; v_a INT; v_old INT; v_new INT; v_d DATE := CURRENT_DATE - 30;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__t_rdi_rec__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
  v_old := finance.fn_add_recurring_payment(v_a, -20, 'Alt', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                            v_d, v_d, NULL, NULL, NULL);                      -- due D-30 -> <= Stichtag-10
  v_new := finance.fn_add_recurring_payment(v_a, -20, 'Neu', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                            CURRENT_DATE - 5, CURRENT_DATE - 5, NULL, NULL, NULL); -- due D-5 -> bleibt offen
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 0));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'skipped_occurrences')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL (5) skipped_occurrences: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_old AND due_date = v_d) THEN
    RAISE EXCEPTION 'FAIL (5): altes Vorkommen nicht als Skip materialisiert'; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_new) THEN
    RAISE EXCEPTION 'FAIL (5): juengeres Vorkommen (D-5) faelschlich geschlossen'; END IF;
  RAISE NOTICE 'PASS (5) Abgleich materialisiert due <= Stichtag-10 als Skip (1), juengeres bleibt offen';
END $$;

-- (6) Zins-Guard auf value_date
DO $$
DECLARE v_res JSONB; v_a INT;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__t_rdi_int__","account_type":"cash","currency":"EUR","interest_rate":12,"interest_credit_unit":"month","interest_credit_day_of_month":1,"interest_day_count_convention":"30E/360","interest_valid_from":"2026-01-01"}'::jsonb
  ) INTO v_res;
  v_a := (v_res->>'account_id')::int;
  UPDATE finance.accounts SET last_reconciled_at = DATE '2026-03-10', last_reconciled_balance = 0 WHERE id = v_a;
  v_res := finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_a, 'value_date', '2026-03-05', 'period_end', '2026-03-01', 'amount', 5));
  IF v_res->>'code' IS DISTINCT FROM 'reconciled' THEN RAISE EXCEPTION 'FAIL (6) Zins-Guard: %', v_res; END IF;
  v_res := finance.fn_book_interest_occurrence(jsonb_build_object(
    'account_id', v_a, 'value_date', '2026-04-05', 'period_end', '2026-04-01', 'amount', 5));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (6) nach Abgleich: %', v_res; END IF;
  RAISE NOTICE 'PASS (6) Zinsgutschrift im abgeglichenen Zeitraum -> reconciled';
END $$;

-- (7) Kreditrate mit Ist-Datum
DO $$
DECLARE v_res JSONB; v_giro INT; v_loan INT; v_lacc INT; v_rp INT; v_date DATE; v_due DATE;
        v_d DATE := CURRENT_DATE - 20;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__t_rdi_lgiro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__t_rdi_kredit__','lender','B','borrower','T',
    'original_amount',200000,'current_balance',200000,'disbursement_date',(v_d - 30)::text,'interest_rate',3.6,
    'monthly_annuity',1000,'first_payment_date',v_d::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int; v_lacc := (v_res->>'loan_account_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.loans WHERE id = v_loan;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d, 'transaction_date', (v_d + 2)::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (7) book: %', v_res; END IF;
  SELECT transaction_date, recurring_due_date INTO v_date, v_due FROM finance.transactions WHERE id = (v_res->>'transaction_id')::int;
  IF v_date IS DISTINCT FROM v_d + 2 OR v_due IS DISTINCT FROM v_d OR (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 199600 THEN
    RAISE EXCEPTION 'FAIL (7): date=% due=% res=%', v_date, v_due, v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) WHERE recurring_payment_id = v_rp AND due_date = v_d) THEN
    RAISE EXCEPTION 'FAIL (7): Kredit-Vorkommen bleibt offen'; END IF;
  RAISE NOTICE 'PASS (7) Kreditrate am Ist-Datum, Identitaet = Faelligkeit, Restschuld 199600';
END $$;

-- (8) Sparplan-Ausfuehrung ueber rp + Faelligkeit + Ist-Datum
DO $$
DECLARE v_res JSONB; v_settle INT; v_depot INT; v_rp INT; v_date DATE; v_due DATE;
        v_d DATE := CURRENT_DATE - 12;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__t_rdi_settle__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__t_rdi_depot__','account_type','stocks_depot','currency','EUR',
    'settlement_id', v_settle))->>'account_id')::int INTO v_depot;
  v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__t_rdi_plan__','depot_name','__t_rdi_depot__',
    'isin','IE00B3RBWM25','symbol','VWCE','security_name','All-World','amount',100,'schedule_interval',1,
    'schedule_unit','month','first_payment_date',v_d::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP (8): %', v_res; END IF;
  SELECT recurring_payment_id INTO v_rp FROM finance.savings_plans WHERE name = '__t_rdi_plan__';
  v_res := finance.fn_book_savings_plan_execution(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d::text, 'transaction_date', (v_d + 2)::text,
    'shares', 0.5, 'price_per_share', 200));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (8) exec: %', v_res; END IF;
  SELECT transaction_date, recurring_due_date INTO v_date, v_due FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int;
  IF v_date IS DISTINCT FROM v_d + 2 OR v_due IS DISTINCT FROM v_d OR (v_res->>'due_date')::date IS DISTINCT FROM v_d THEN
    RAISE EXCEPTION 'FAIL (8): date=% due=% res=%', v_date, v_due, v_res; END IF;
  RAISE NOTICE 'PASS (8) Sparplan-Ausfuehrung ueber rp/Faelligkeit am Ist-Datum';
END $$;

-- (9) Split-Stichtag keyt auf die Faelligkeit
DO $$
DECLARE v_res JSONB; v_a INT; v_rp INT; v_d DATE := CURRENT_DATE - 40;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__t_rdi_split__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
  v_rp := finance.fn_add_recurring_payment(v_a, -85, 'Strom', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                           v_d, v_d, NULL, NULL, NULL);
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object(
    'recurring_payment_id', v_rp, 'due_date', v_d, 'amount', 92, 'transaction_date', (v_d + 3)::text));
  v_res := finance.fn_split_recurring_payment(v_rp, v_d + 1, -92, NULL, NULL, NULL, NULL, NULL, NULL);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (9) split ab due+1: %', v_res; END IF;
  RAISE NOTICE 'PASS (9) Split ab Faelligkeit+1 trotz spaeterem Buchungsdatum';
END $$;

ROLLBACK;
