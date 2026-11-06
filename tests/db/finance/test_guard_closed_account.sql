-- tests/db/finance/test_guard_closed_account.sql
-- Testet trg_finance_reject_closed_account: INSERT auf einem status='closed'-Konto wird blockiert.
-- Pattern: innerer BEGIN/EXCEPTION-Block (Savepoint) faengt die erwartete Blockade; Flag prueft danach.
BEGIN;

DO $$
DECLARE v_acct INT; v_blocked BOOLEAN := FALSE; v_cnt INT;
BEGIN
  SELECT (finance.fn_create_account(
    '{"name":"__closed__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb
  )->>'account_id')::int INTO v_acct;

  UPDATE finance.accounts SET status = 'closed' WHERE id = v_acct;

  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
    VALUES (v_acct, 50, CURRENT_DATE, 'other', 'sollte blockiert werden');
  EXCEPTION WHEN OTHERS THEN
    v_blocked := TRUE;   -- erwartete Blockade durch den Trigger
  END;

  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL guard_closed_account: INSERT auf geschlossenem Konto wurde NICHT blockiert';
  END IF;

  SELECT COUNT(*) INTO v_cnt FROM finance.transactions WHERE account_id = v_acct;
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'FAIL guard_closed_account: Txn trotz Blockade vorhanden (count=%)', v_cnt;
  END IF;

  RAISE NOTICE 'PASS guard_closed_account: INSERT auf closed-Konto blockiert (kein Residual)';
END $$;

ROLLBACK;
