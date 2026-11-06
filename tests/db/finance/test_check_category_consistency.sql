-- tests/db/finance/test_check_category_consistency.sql
-- Testet CHECK finance_transactions_category_consistency: ungueltige Kombinationen werden abgelehnt.
-- Jede Verletzung in eigenem BEGIN/EXCEPTION-Block (Savepoint) -> Flag prueft, dass sie blockt.
BEGIN;

DO $$
DECLARE
  v_cash INT; v_settle INT; v_depot INT; v_holding INT; v_blocked BOOLEAN;
BEGIN
  -- Setup: Cash-Konto + Depot + Holding (fuer holding_id-abhaengige Faelle)
  SELECT (finance.fn_create_account('{"name":"__cc_cash__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_cash;
  SELECT (finance.fn_create_account('{"name":"__cc_settle__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__cc_depot__','account_type','stocks_depot','account_holder','T','currency','EUR','settlement_id',v_settle))->>'account_id')::int INTO v_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'CCISIN', 'CC', 'CC ETF', 0, NULL, 'EUR') RETURNING id INTO v_holding;

  -- (1) buy OHNE holding_id -> verletzt 'buy ⟹ holding_id NOT NULL'
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares)
    VALUES (v_cash, -100, CURRENT_DATE, 'buy', NULL, 1);
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL category [buy ohne holding_id nicht blockiert]'; END IF;

  -- (2) fee mit POSITIVEM Betrag -> verletzt 'fee ⟹ amount < 0'
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_cash, 10, CURRENT_DATE, 'fee');
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL category [fee mit positivem Betrag nicht blockiert]'; END IF;

  -- (3) dividend MIT shares -> verletzt 'dividend ⟹ shares IS NULL'
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares)
    VALUES (v_cash, 10, CURRENT_DATE, 'dividend', v_holding, 5);
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL category [dividend mit shares nicht blockiert]'; END IF;

  -- (4) loan_payment OHNE loan_id -> verletzt 'loan_payment ⟹ loan_id NOT NULL'
  v_blocked := FALSE;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
    VALUES (v_cash, -50, CURRENT_DATE, 'loan_payment', NULL);
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL category [loan_payment ohne loan_id nicht blockiert]'; END IF;

  -- Kontrolle: gueltige 'other'-Buchung wird akzeptiert
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_cash, 5, CURRENT_DATE, 'other');

  RAISE NOTICE 'PASS check_category_consistency: 4 Verletzungen blockiert, gueltige Buchung akzeptiert';
END $$;

ROLLBACK;
