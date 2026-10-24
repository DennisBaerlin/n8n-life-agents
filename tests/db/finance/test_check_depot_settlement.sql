-- tests/db/finance/test_check_depot_settlement.sql
-- Testet CHECK finance_accounts_depot_needs_settlement: Depot-Konten brauchen settlement_account_id;
-- Nicht-Depot-Konten duerfen ohne. Verletzungen in BEGIN/EXCEPTION-Block (Savepoint) + Flag.
BEGIN;

DO $$
DECLARE v_blocked BOOLEAN; v_id INT;
BEGIN
  -- (1) stocks_depot OHNE settlement -> blockiert
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.accounts (name, account_type) VALUES ('__ds_depot__', 'stocks_depot');
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL depot_settlement: stocks_depot ohne settlement NICHT blockiert'; END IF;

  -- (2) crypto_depot OHNE settlement -> blockiert
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.accounts (name, account_type) VALUES ('__ds_crypto__', 'crypto_depot');
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL depot_settlement: crypto_depot ohne settlement NICHT blockiert'; END IF;

  -- (3) Kontrolle: cash OHNE settlement -> erlaubt
  INSERT INTO finance.accounts (name, account_type) VALUES ('__ds_cash__', 'cash') RETURNING id INTO v_id;
  IF v_id IS NULL THEN RAISE EXCEPTION 'FAIL depot_settlement: cash ohne settlement sollte erlaubt sein'; END IF;

  RAISE NOTICE 'PASS check_depot_settlement: stocks_depot/crypto_depot ohne settlement blockiert, cash erlaubt';
END $$;

ROLLBACK;
