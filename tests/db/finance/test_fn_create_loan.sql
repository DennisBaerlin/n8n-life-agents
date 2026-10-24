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

-- ============================================================
-- Live-Befund 2026-10-24 (erfundene Werte): laufender Kredit = Restschuld HEUTE + Zins + Rate + naechste Faelligkeit
--   (A) Eroeffnung zum Stichtag heute (nicht zum Auszahlungsdatum), Kreditkonto mit opening_balance_date;
--   (C) Ursprungswerte optional, Aufteilung der 1. Rate aus der Restschuld, Rate < Monatszins abgelehnt.
-- ============================================================
DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_acc   INT;
  v_base  JSONB;
  r       RECORD;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_lr_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  -- laufend: nur Restschuld 95.000 / Zins 1,2 % / Rate 600 / naechste Faelligkeit / Abbuchungskonto
  v_base := jsonb_build_object('lender','Testbank','current_balance',95000,'interest_rate',1.2,
    'monthly_annuity',600,'schedule_day_of_month',-2,'first_payment_date',(core.fn_today() + 20)::text,
    'debit_account_id',v_giro);

  v_res := finance.fn_create_loan(v_base || '{"name":"__test_lr_minimal__"}'::jsonb);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [laufend minimal]: ok:true erwartet (Ursprungswerte optional), got %', v_res; END IF;
  v_acc := (v_res->>'loan_account_id')::int;
  -- (A) Eroeffnung heute, nicht vorher
  IF (SELECT transaction_date FROM finance.transactions WHERE account_id = v_acc AND category = 'disbursement')
     IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [laufend Stichtag]: Eroeffnung nicht zum Stichtag heute'; END IF;
  IF finance.fn_get_balance_as_of(v_acc, core.fn_today() - 1) IS DISTINCT FROM 0::numeric THEN
    RAISE EXCEPTION 'FAIL [laufend Stichtag]: Saldo gestern % statt 0', finance.fn_get_balance_as_of(v_acc, core.fn_today() - 1); END IF;
  IF (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acc) IS DISTINCT FROM core.fn_today()
     OR (v_res->>'opening_balance_date')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [laufend Stichtag]: opening_balance_date nicht heute, got %', v_res; END IF;
  -- Rate zaehlt ab Stichtag; -2 gespeichert
  IF (SELECT valid_from FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int) < core.fn_today()
     OR (SELECT schedule_day_of_month FROM finance.loans WHERE id = (v_res->>'loan_id')::int) IS DISTINCT FROM -2 THEN
    RAISE EXCEPTION 'FAIL [laufend rp]: valid_from vor heute oder -2 nicht gespeichert'; END IF;
  -- Post-State: Restschuld + DB-Aufteilung der 1. Rate (95.000 * 1,2 % / 12 = 95,00 Zins, 505,00 Tilgung)
  IF (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 95000
     OR (v_res->>'first_rate_interest')::numeric IS DISTINCT FROM 95.00
     OR (v_res->>'first_rate_principal')::numeric IS DISTINCT FROM 505.00
     OR v_res->'disbursement_balance' IS DISTINCT FROM 'null'::jsonb THEN
    RAISE EXCEPTION 'FAIL [laufend Post-State]: got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.loans WHERE id = (v_res->>'loan_id')::int
             AND (original_amount IS NOT NULL OR disbursement_date IS NOT NULL OR principal_rate IS NOT NULL)) THEN
    RAISE EXCEPTION 'FAIL [laufend minimal]: Ursprungswerte nicht NULL'; END IF;
  RAISE NOTICE 'PASS [laufend minimal: Eroeffnung heute, opening_balance_date, rp ab heute, -2, Aufteilung 95/505]';

  -- laufend MIT Ursprungswerten: Eroeffnung trotzdem heute, Werte gespeichert (informativ)
  v_res := finance.fn_create_loan(v_base || jsonb_build_object('name','__test_lr_full__','original_amount',180000,
    'disbursement_date','2016-05-02','principal_rate',4.2));
  v_acc := (v_res->>'loan_account_id')::int;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT transaction_date FROM finance.transactions WHERE account_id = v_acc AND category = 'disbursement')
        IS DISTINCT FROM core.fn_today()
     OR NOT EXISTS (SELECT 1 FROM finance.loans WHERE id = (v_res->>'loan_id')::int
                    AND original_amount = 180000 AND disbursement_date = '2016-05-02' AND principal_rate = 4.2) THEN
    RAISE EXCEPTION 'FAIL [laufend voll]: Eroeffnung heute + Ursprungswerte gespeichert erwartet, got %', v_res; END IF;
  RAISE NOTICE 'PASS [laufend mit Ursprungswerten: Eroeffnung heute, Werte informativ gespeichert]';

  -- Korrigierbare Ablehnungen ohne Write
  FOR r IN SELECT * FROM (VALUES
      ('frisch ohne Betrag',       '{"current_balance":"","disbursement_date":"2026-01-02"}'::jsonb),
      ('frisch ohne Datum',        '{"current_balance":"","original_amount":50000}'::jsonb),
      ('Auszahlung ohne Betrag',   jsonb_build_object('disbursement_account_id', v_giro)),
      ('Rate unter Monatszins',    '{"monthly_annuity":90}'::jsonb),
      ('Zinssatz fehlt',           '{"interest_rate":""}'::jsonb)
    ) t(label, delta)
  LOOP
    v_res := finance.fn_create_loan(v_base || r.delta || jsonb_build_object('name','__test_lr_' || r.label));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' IS NULL
       OR EXISTS (SELECT 1 FROM finance.loans WHERE name = '__test_lr_' || r.label) THEN
      RAISE EXCEPTION 'FAIL [guard %]: ok:false ohne Write erwartet, got %', r.label, v_res; END IF;
  END LOOP;
  v_res := finance.fn_create_loan(v_base || '{"name":"__test_lr_low__","monthly_annuity":90}'::jsonb);
  IF (v_res->>'interest')::numeric IS DISTINCT FROM 95.00 THEN
    RAISE EXCEPTION 'FAIL [Rate unter Monatszins]: Zins 95,00 im Ergebnis erwartet, got %', v_res; END IF;
  -- Restschuld > Kreditbetrag nennt genau diesen Grund (nicht "neuer Kredit braucht ...")
  v_res := finance.fn_create_loan(v_base || '{"name":"__test_lr_over__","original_amount":20000,"current_balance":25000}'::jsonb);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not above the original amount%' THEN
    RAISE EXCEPTION 'FAIL [Restschuld > Betrag]: falscher Grund, got %', v_res; END IF;
  RAISE NOTICE 'PASS [Guards: frisch ohne Betrag/Datum, Auszahlungskonto ohne Betrag, Rate < Monatszins, Zins fehlt, Restschuld > Betrag]';

  -- Frischer Kredit: Eroeffnung bleibt am Auszahlungsdatum; Post-State beider Konten + Aufteilung
  DECLARE v_disb INT;
  BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_lr_payout__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_disb;
    v_res := finance.fn_create_loan(jsonb_build_object('name','__test_lr_fresh__','lender','Testbank',
      'original_amount',40000,'disbursement_date',(core.fn_today() - 3)::text,'interest_rate',6,'monthly_annuity',700,
      'first_payment_date',(core.fn_today() + 27)::text,'disbursement_account_id',v_disb,'debit_account_id',v_giro));
    v_acc := (v_res->>'loan_account_id')::int;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT min(transaction_date) FROM finance.transactions WHERE account_id = v_acc) IS DISTINCT FROM core.fn_today() - 3
       OR (SELECT opening_balance_date FROM finance.accounts WHERE id = v_acc) IS NOT NULL
       OR (v_res->>'remaining_debt')::numeric IS DISTINCT FROM 40000
       OR (v_res->>'disbursement_balance')::numeric IS DISTINCT FROM 40000
       OR (v_res->>'first_rate_interest')::numeric IS DISTINCT FROM 200.00
       OR (v_res->>'first_rate_principal')::numeric IS DISTINCT FROM 500.00 THEN
      RAISE EXCEPTION 'FAIL [frisch]: Eroeffnung am Auszahlungstag + Post-State erwartet, got %', v_res; END IF;
  END;
  RAISE NOTICE 'PASS [frisch: Eroeffnung am Auszahlungsdatum, Post-State 40000/40000, Aufteilung 200/500]';

  -- Spiegelnder CHECK: Auszahlungskonto ohne Kreditbetrag (direktes DML)
  BEGIN
    UPDATE finance.loans SET disbursement_account_id = v_giro WHERE name = '__test_lr_minimal__';
    RAISE EXCEPTION 'FAIL [CHECK]: Auszahlungskonto ohne original_amount akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS [CHECK finance_loans_disbursement_needs_amount]';
END $$;

ROLLBACK;
