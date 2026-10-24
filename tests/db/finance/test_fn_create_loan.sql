-- tests/db/finance/test_fn_create_loan.sql
-- Testet fn_create_loan: Loan-Konto + Loan-Row + recurring_payment + Eröffnungs-Txn + Auszahlungs-Txn
BEGIN;

DO $$
DECLARE
  v_result     JSONB;
  v_debit_id          INT;
  v_disbursement_id   INT;
  v_loan_id    INT;
  v_loan_acc   INT;
  v_rp_id      INT;
  v_amount     NUMERIC := 200000;
  v_annuity    NUMERIC := 800;
  v_balance    NUMERIC;
  v_txn_count  INT;
BEGIN

  -- Voraussetzungen: Debit-Konto (Ratenzahlung) + Disbursement-Konto (Kreditauszahlung)
  SELECT finance.fn_create_account(
    '{"name":"__test_loan_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    '{"name":"__test_loan_disbursement__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_disbursement_id := (v_result->>'account_id')::int;

  -- fn_create_loan aufrufen (frischer Kredit, mit Auszahlung auf eigenes Konto)
  SELECT finance.fn_create_loan(
    jsonb_build_object(
      'name',                      '__test_kredit__',
      'lender',                    'TestBank',
      'borrower',                  'Test',
      'original_amount',           v_amount,
      'disbursement_date',         '2024-01-15',
      'interest_rate',             '3.0',
      'principal_rate',            '1.0',
      'interest_rate_fixed_until', '2034-01-15',
      'monthly_annuity',           v_annuity,
      'schedule_day_of_month',     '15',
      'first_payment_date',        '2024-02-15',
      'disbursement_account_id',   v_disbursement_id,
      'debit_account_id',          v_debit_id
    )
  ) INTO v_result;

  IF NOT (v_result ? 'loan_id') THEN
    RAISE EXCEPTION 'FAIL fn_create_loan: kein loan_id in Result, got %', v_result;
  END IF;
  v_loan_id  := (v_result->>'loan_id')::int;
  v_loan_acc := (v_result->>'loan_account_id')::int;
  v_rp_id    := (v_result->>'recurring_payment_id')::int;

  -- Assert 1: Loan-Konto (account_type=loan) angelegt
  IF NOT EXISTS (
    SELECT 1 FROM finance.accounts
    WHERE id = v_loan_acc AND account_type = 'loan' AND name = 'Kredit __test_kredit__'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [1]: Loan-Konto nicht angelegt (id=%)', v_loan_acc;
  END IF;

  -- Assert 1b: Zahl-Rhythmus-Tag landete in der umbenannten Spalte schedule_day_of_month (5e)
  IF NOT EXISTS (
    SELECT 1 FROM finance.loans WHERE id = v_loan_id AND schedule_day_of_month = 15
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [1b]: schedule_day_of_month nicht 15 (loan_id=%)', v_loan_id;
  END IF;

  -- Assert 2: Loan-Eröffnungssaldo = -original_amount (disbursement trigger)
  SELECT finance.fn_get_balance(v_loan_acc) INTO v_balance;
  IF v_balance IS DISTINCT FROM -v_amount THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [2]: Loan-Konto-Balance sollte %, got %', -v_amount, v_balance;
  END IF;

  -- Assert 3: recurring_payment für Monatsrate angelegt
  IF v_rp_id IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [3]: recurring_payment_id ist NULL (Annuität war gesetzt)';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM finance.recurring_payments
    WHERE id = v_rp_id AND amount = -v_annuity AND account_id = v_debit_id
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [3]: recurring_payment nicht korrekt (rp_id=%)', v_rp_id;
  END IF;

  -- Assert 4: Auszahlungs-Txn auf Disbursement-Konto (+original_amount)
  SELECT finance.fn_get_balance(v_disbursement_id) INTO v_balance;
  IF v_balance IS DISTINCT FROM v_amount THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [4]: Disbursement-Balance sollte %, got %', v_amount, v_balance;
  END IF;

  -- Assert 5: Beide Transaktionen (Eröffnung + Auszahlung) mit category=disbursement
  SELECT COUNT(*) INTO v_txn_count
  FROM finance.transactions
  WHERE loan_id = v_loan_id AND category = 'disbursement';

  IF v_txn_count <> 2 THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [5]: erwartet 2 disbursement-Txns, got %', v_txn_count;
  END IF;

  RAISE NOTICE 'PASS fn_create_loan: loan_id=%, loan_acc=%, rp_id=%, txns=%',
    v_loan_id, v_loan_acc, v_rp_id, v_txn_count;

  -- Assert 6 (WS-4): der bisher OHNE borrower_person_id angelegte Kredit -> NULL = Haushalt.
  IF NOT EXISTS (SELECT 1 FROM finance.loans WHERE id = v_loan_id AND borrower_person_id IS NULL) THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [6]: ohne borrower_person_id muss NULL=Haushalt sein';
  END IF;
  -- Mit typisiertem Kreditnehmer (Slug):
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_loan_borrower', 'Test Kreditnehmer', 'partner') ON CONFLICT (person_id) DO NOTHING;
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_kredit_b__','lender','TestBank','borrower_person_id','__test_loan_borrower',
    'original_amount',50000,'disbursement_date','2024-01-15','interest_rate','3.0','principal_rate','1.0',
    'monthly_annuity',300,'schedule_day_of_month','15','first_payment_date','2024-02-15','debit_account_id',v_debit_id
  )) INTO v_result;
  v_loan_id := (v_result->>'loan_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.loans WHERE id = v_loan_id AND borrower_person_id = '__test_loan_borrower') THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [6b]: borrower_person_id nicht gesetzt (id=%)', v_loan_id;
  END IF;
  RAISE NOTICE 'PASS fn_create_loan [6 borrower_person_id Slug gesetzt + NULL=Haushalt]';

END $$;

-- ============================================================
-- Eindeutigkeit/Audit 2026-10-21: korrigierbare Ablehnungen VOR dem Write + Raten-Stichtag
-- ============================================================
DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_usd   INT;
  v_open  INT;
  v_base  JSONB;
  r       RECORD;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_lg_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__test_lg_usd__","account_type":"cash","currency":"USD"}'::jsonb)->>'account_id')::int INTO v_usd;
  v_base := jsonb_build_object('lender','Bank','original_amount',20000,'disbursement_date','2020-01-01',
    'interest_rate',4,'schedule_day_of_month',1,'debit_account_id',v_giro);

  FOR r IN SELECT * FROM (VALUES
      ('rate ohne Datum',        jsonb_build_object('monthly_annuity',350)),
      ('Restschuld > Summe',     jsonb_build_object('current_balance',25000)),
      ('Restschuld 0',           jsonb_build_object('current_balance',0)),
      ('Auszahlung bei laufend', jsonb_build_object('current_balance',15000,'disbursement_account_id',v_giro)),
      ('USD-Abbuchungskonto',    jsonb_build_object('debit_account_id',v_usd))
    ) t(label, delta)
  LOOP
    SELECT finance.fn_create_loan(v_base || r.delta || jsonb_build_object('name','__test_lg_' || r.label)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false
       OR EXISTS (SELECT 1 FROM finance.loans WHERE name = '__test_lg_' || r.label) THEN
      RAISE EXCEPTION 'FAIL fn_create_loan [guard %]: ok=false ohne Write erwartet, got %', r.label, v_res;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS fn_create_loan [Guards: Rate ohne Datum, Restschuld >Summe/0, Auszahlung bei laufendem Kredit, USD-Konto]';

  -- Laufender Kredit auf Konto mit Eroeffnungssaldo: Rate zaehlt ab Stichtag, Anker bleibt
  SELECT (finance.fn_create_account('{"name":"__test_lg_open__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int INTO v_open;
  SELECT finance.fn_create_loan(v_base || jsonb_build_object('name','__test_lg_running','current_balance',15000,
    'monthly_annuity',350,'first_payment_date','2020-02-01','debit_account_id',v_open)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT valid_from::text || '|' || first_payment_date FROM finance.recurring_payments
         WHERE id = (v_res->>'recurring_payment_id')::int) IS DISTINCT FROM CURRENT_DATE::text || '|2020-02-01' THEN
    RAISE EXCEPTION 'FAIL fn_create_loan [stichtag]: Rate ab heute + Anker 2020-02-01 erwartet, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS fn_create_loan [laufender Kredit: Rate ab Eroeffnungssaldo-Stichtag]';
END $$;

ROLLBACK;
