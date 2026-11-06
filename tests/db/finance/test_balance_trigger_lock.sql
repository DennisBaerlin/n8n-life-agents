-- tests/db/finance/test_balance_trigger_lock.sql
-- Audit Paket 2, Punkt 12: Saldo-Trigger update_finance_balance — Race Cron || Chat.
--   Vorher summierte der Trigger VOR dem Konflikt-Lock (INSERT ... ON CONFLICT DO UPDATE): zwei parallele Buchungen
--   auf dasselbe Konto lasen je einen Snapshot ohne die andere -> der zweite Upsert ueberschrieb den Saldo mit einer
--   Summe ohne die erste Buchung (Lost Update). Jetzt: Saldo-Zeile zuerst sperren (FOR UPDATE), DANN summieren —
--   in READ COMMITTED nimmt die folgende Anweisung einen neuen Snapshot und sieht die committete Parallel-Buchung.
--   TESTGRENZE: das Framework hat keine zweite Verbindung (kein dblink; jede Datei endet mit ROLLBACK) -> die Race
--   selbst ist hier nicht nachstellbar. Deshalb (a) struktureller Test: in BEIDEN Zweigen steht die Sperre vor der
--   Summe, (b) funktionaler Test: der Saldo stimmt nach INSERT / UPDATE (Kontowechsel) / DELETE.
BEGIN;

DO $$
DECLARE
  v_def  TEXT;
  v_lock INT;
  v_sum  INT;
  v_a    INT;
  v_b    INT;
  v_tx   INT;
BEGIN
  -- (a) strukturell: erste Sperre vor der ersten Summe, und eine zweite Sperre (OLD-Zweig) vor der zweiten Summe
  v_def  := pg_get_functiondef('finance.update_finance_balance()'::regprocedure);
  v_lock := strpos(v_def, 'FOR UPDATE');
  v_sum  := strpos(v_def, 'SUM(amount)');
  IF v_lock = 0 OR v_sum = 0 OR v_lock > v_sum THEN
    RAISE EXCEPTION 'FAIL balance-lock [Sperre vor Summe]: FOR UPDATE an %, SUM an %', v_lock, v_sum; END IF;
  IF strpos(substr(v_def, v_sum + 1), 'FOR UPDATE') = 0
     OR strpos(substr(v_def, v_sum + 1), 'FOR UPDATE') > strpos(substr(v_def, v_sum + 1), 'SUM(amount)') THEN
    RAISE EXCEPTION 'FAIL balance-lock [OLD-Zweig]: keine Sperre vor der zweiten Summe'; END IF;
  RAISE NOTICE 'PASS balance-lock [Saldo-Zeile wird in beiden Zweigen VOR dem Summieren gesperrt]';

  -- (b) funktional
  SELECT (finance.fn_create_account('{"name":"__test_btl_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
  SELECT (finance.fn_create_account('{"name":"__test_btl_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_b;
  INSERT INTO finance.transactions (account_id, amount, transaction_date) VALUES (v_a, 100, CURRENT_DATE) RETURNING id INTO v_tx;
  INSERT INTO finance.transactions (account_id, amount, transaction_date) VALUES (v_a, 50, CURRENT_DATE);
  IF finance.fn_get_balance(v_a) IS DISTINCT FROM 150.00 THEN RAISE EXCEPTION 'FAIL balance [INSERT]: %', finance.fn_get_balance(v_a); END IF;
  UPDATE finance.transactions SET account_id = v_b WHERE id = v_tx;
  IF finance.fn_get_balance(v_a) IS DISTINCT FROM 50.00 OR finance.fn_get_balance(v_b) IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL balance [UPDATE Kontowechsel]: a=% b=%', finance.fn_get_balance(v_a), finance.fn_get_balance(v_b); END IF;
  DELETE FROM finance.transactions WHERE id = v_tx;
  IF finance.fn_get_balance(v_b) IS DISTINCT FROM 0.00 THEN RAISE EXCEPTION 'FAIL balance [DELETE]: %', finance.fn_get_balance(v_b); END IF;
  RAISE NOTICE 'PASS balance [INSERT / UPDATE Kontowechsel / DELETE]';
END $$;

ROLLBACK;
