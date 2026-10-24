-- tests/db/finance/test_fn_rollback_atomicity.sql
-- Testet atomare Rollback-Semantik: bei Fehler in fn_* darf kein Partial-State übrig bleiben.
-- Nutzt innere BEGIN/EXCEPTION-Blöcke (PL/pgSQL-Savepoints) um erwartete Fehler zu catchen,
-- ohne die äußere Transaktion abzubrechen.
BEGIN;

DO $$
DECLARE
  v_result       JSONB;
  v_debit_id     INT;
  v_loan_name    TEXT := '__test_loan_atomic__';
  v_count_before INT;
  v_count_after  INT;
BEGIN

  -- Voraussetzung: ein gültiges Debit-Konto (für spätere positive Tests)
  SELECT finance.fn_create_account(
    '{"name":"__test_atomic_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit_id := (v_result->>'account_id')::int;

  -- TEST 1: fn_create_loan mit ungültigem debit_account_id (FK-Verletzung)
  -- Erwartet: EXCEPTION → kein Loan-Konto angelegt (atomarer Rollback)
  SELECT COUNT(*) INTO v_count_before
  FROM finance.accounts WHERE name = 'Kredit ' || v_loan_name;

  BEGIN  -- innerer Block: Savepoint + Exception-Handler
    SELECT finance.fn_create_loan(
      jsonb_build_object(
        'name',                      v_loan_name,
        'lender',                    'TestBank',
        'borrower',                  'Test',
        'original_amount',           '100000',
        'disbursement_date',         '2024-01-01',
        'interest_rate',             '3.0',
        'principal_rate',            '1.0',
        'interest_rate_fixed_until', '2034-01-01',
        'monthly_annuity',           '500',
        'schedule_day_of_month',      '1',
        'debit_account_id',          999999   -- nicht existent → FK-Verletzung → Rollback
      )
    ) INTO v_result;
    -- Wenn wir hier ankommen, wurde KEIN Fehler geworfen → Test schlägt fehl
    RAISE EXCEPTION 'FAIL atomicity [1]: fn_create_loan hätte FK-Exception werfen sollen';
  EXCEPTION WHEN OTHERS THEN
    NULL;  -- erwarteter Fehler gecatcht (Savepoint rollt Partial-Inserts zurück)
  END;

  SELECT COUNT(*) INTO v_count_after
  FROM finance.accounts WHERE name = 'Kredit ' || v_loan_name;

  IF v_count_after <> v_count_before THEN
    RAISE EXCEPTION 'FAIL atomicity [1]: Partial-Data übrig geblieben! count vor=%, nach=%',
      v_count_before, v_count_after;
  END IF;

  RAISE NOTICE 'PASS fn_rollback_atomicity [1 FK-Verletzung]: kein Partial-State (count=% unverändert)', v_count_after;

  -- TEST 2: fn_book_transaction mit ungültiger direction → Rollback auf Fn-Level
  SELECT finance.fn_create_account(
    '{"name":"__test_atomic_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  DECLARE
    v_acct_id INT := (v_result->>'account_id')::int;
    v_tx_count_before INT;
    v_tx_count_after  INT;
  BEGIN
    SELECT COUNT(*) INTO v_tx_count_before
    FROM finance.transactions WHERE account_id = v_acct_id;

    BEGIN
      SELECT finance.fn_book_transaction(
        jsonb_build_object(
          'account_id',       v_acct_id,
          'amount',           '100',
          'direction',        'invalid_direction',  -- ungültig → RAISE in fn
          'transaction_date', CURRENT_DATE::text
        )
      ) INTO v_result;
      RAISE EXCEPTION 'FAIL atomicity [2]: fn_book_transaction hätte RAISE werfen sollen';
    EXCEPTION WHEN OTHERS THEN
      NULL;
    END;

    SELECT COUNT(*) INTO v_tx_count_after
    FROM finance.transactions WHERE account_id = v_acct_id;

    IF v_tx_count_after <> v_tx_count_before THEN
      RAISE EXCEPTION 'FAIL atomicity [2]: Txn wurde trotz Fehler angelegt (vor=%, nach=%)',
        v_tx_count_before, v_tx_count_after;
    END IF;

    RAISE NOTICE 'PASS fn_rollback_atomicity [2 ungültige direction]: kein Txn angelegt';
  END;

END $$;

ROLLBACK;
