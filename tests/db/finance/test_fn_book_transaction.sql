-- tests/db/finance/test_fn_book_transaction.sql
-- Testet fn_book_transaction: Einzel-Txn gegen externe Gegenseite (inflow + outflow)
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_acct_id INT;
  v_tx_id   INT;
  v_balance NUMERIC;
  v_rb_acct INT;
  v_rb_goal INT;
BEGIN

  -- Voraussetzung: ein Cash-Konto
  SELECT finance.fn_create_account(
    '{"name":"__test_btx_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- TEST 1: inflow 1000 EUR (z.B. Gehalt)
  SELECT finance.fn_book_transaction(
    jsonb_build_object(
      'account_id',       v_acct_id,
      'amount',           '1000',
      'direction',        'inflow',
      'category',         'other',
      'description',      'Testgehalt',
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  IF NOT (v_result ? 'tx_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [1]: kein tx_id, got %', v_result;
  END IF;
  IF (v_result->>'amount')::numeric IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [1]: amount sollte 1000, got %', v_result->>'amount';
  END IF;

  SELECT finance.fn_get_balance(v_acct_id) INTO v_balance;
  IF v_balance IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [1]: Balance nach inflow sollte 1000, got %', v_balance;
  END IF;
  IF (v_result->>'account_balance')::numeric IS DISTINCT FROM v_balance THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [1 return account_balance]: erwartet %, got %', v_balance, v_result->>'account_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_transaction [1 inflow]: balance=%', v_balance;

  -- TEST 2: outflow 350 EUR (z.B. Miete)
  SELECT finance.fn_book_transaction(
    jsonb_build_object(
      'account_id',       v_acct_id,
      'amount',           '350',
      'direction',        'outflow',
      'description',      'Testmiete',
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  IF (v_result->>'amount')::numeric IS DISTINCT FROM -350 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [2]: amount sollte -350, got %', v_result->>'amount';
  END IF;

  SELECT finance.fn_get_balance(v_acct_id) INTO v_balance;
  IF v_balance IS DISTINCT FROM 650 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [2]: Balance nach outflow sollte 650, got %', v_balance;
  END IF;
  IF (v_result->>'account_balance')::numeric IS DISTINCT FROM v_balance THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [2 return account_balance]: erwartet %, got %', v_balance, v_result->>'account_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_transaction [2 outflow]: balance=%', v_balance;

  -- TEST 3: category=fee (muss outflow sein, wird vom fn geprüft)
  SELECT finance.fn_book_transaction(
    jsonb_build_object(
      'account_id',       v_acct_id,
      'amount',           '10',
      'direction',        'outflow',
      'category',         'fee',
      'description',      'Kontogebuehr',
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = (v_result->>'tx_id')::int AND category = 'fee' AND amount = -10
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [3]: fee-Txn nicht korrekt';
  END IF;

  RAISE NOTICE 'PASS fn_book_transaction [3 fee]: tx_id=%', v_result->>'tx_id';

  -- TEST 4: ungueltige direction -> {ok:false} (korrigierbar, kein RAISE)
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '50', 'direction', 'sideways',
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [bad direction]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [bad direction -> ok:false]';

  -- TEST 5: amount <= 0 -> {ok:false}
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '0', 'direction', 'inflow',
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [amount<=0 -> ok:false]';

  -- TEST 6: category=fee mit inflow -> {ok:false}
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '10', 'direction', 'inflow', 'category', 'fee',
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [fee inflow]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [fee inflow -> ok:false]';

  -- TEST 7 (WS-C2 Reserve-Waechter): un-getaggte Belastung drueckt Saldo unter die getaggte Reserve ->
  -- die fn faltet reserve_breach in {ok:true,...} (NUR bei Outflow; Inflow nie).
  SELECT finance.fn_create_account('{"name":"__btx_rb__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result;
  v_rb_acct := (v_result->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__btx_rb_goal__', 5000, current_date + 365, 'active') RETURNING id INTO v_rb_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_rb_acct, 500, current_date - 10, 'transfer', v_rb_goal, gen_random_uuid());   -- Reserve-Zufluss (getaggt) -> Saldo 500, reserviert 500

  -- (a) Outflow 400 -> Saldo 100 < reserviert 500 -> reserve_breach gesetzt, shortfall 400.
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_rb_acct, 'amount', '400', 'direction', 'outflow', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
  IF NOT (v_result ? 'reserve_breach') OR (v_result->'reserve_breach'->>'shortfall')::numeric IS DISTINCT FROM 400 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [reserve_breach]: erwartet reserve_breach mit shortfall 400, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [7a: Outflow unter Reserve -> reserve_breach shortfall 400]';

  -- (b) Inflow 50 -> kein reserve_breach (eine Gutschrift kann nie breachen; trotz Restunterdeckung kein „du hast eingegriffen").
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_rb_acct, 'amount', '50', 'direction', 'inflow', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
  IF v_result ? 'reserve_breach' THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [reserve_breach inflow]: eine Gutschrift darf kein reserve_breach falten, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [7b: Inflow faltet kein reserve_breach]';

  -- (c) Outflow auf einem Konto OHNE Reserve -> kein reserve_breach.
  SELECT finance.fn_create_account('{"name":"__btx_norb__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '100', 'direction', 'outflow', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
  IF v_result ? 'reserve_breach' THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [reserve_breach no-reserve]: ohne Reserve kein Breach, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transaction [7c: Outflow ohne Reserve -> kein reserve_breach]';

  -- TEST 8 (Audit Paket 2, Punkt 8): Betrag wird vor dem Buchen auf die Waehrungseinheit gerundet -> Rueckgabe =
  -- gespeicherter Wert (vorher 10.005 zurueck, 10.01 gespeichert); 0.004 rundet auf 0 -> ok:false.
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '10.005', 'direction', 'outflow', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
  IF (v_result->>'amount')::numeric IS DISTINCT FROM -10.01
     OR (SELECT amount FROM finance.transactions WHERE id = (v_result->>'tx_id')::int) IS DISTINCT FROM -10.01 THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [Rundung]: Rueckgabe/gespeichert erwartet -10.01, got %', v_result; END IF;
  SELECT finance.fn_book_transaction(jsonb_build_object(
    'account_id', v_acct_id, 'amount', '0.004', 'direction', 'outflow', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transaction [0.004]: erwartet ok=false, got %', v_result; END IF;
  RAISE NOTICE 'PASS fn_book_transaction [8: 10.005 -> 10.01 in Rueckgabe und Speicher, 0.004 -> ok:false]';

  -- TEST 9 (Audit Paket 2, Punkt 8): strukturelle Kategorien (Kauf/Verkauf/Kredit/Abgleich) und "transfer"
  -- (einbeinig) -> ok:false statt CHECK-RAISE + Owner-Alarm bzw. stiller Halb-Buchung.
  DECLARE v_cat TEXT; v_cnt0 INT; BEGIN
    SELECT count(*) INTO v_cnt0 FROM finance.transactions;
    FOREACH v_cat IN ARRAY ARRAY['buy','sell','dividend','principal','loan_payment','disbursement','settlement',
                                 'reconciliation','transfer'] LOOP
      SELECT finance.fn_book_transaction(jsonb_build_object('account_id', v_acct_id, 'amount', '20',
        'direction', 'inflow', 'category', v_cat, 'transaction_date', CURRENT_DATE::text)) INTO v_result;
      IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL fn_book_transaction [Kategorie %]: erwartet ok=false, got %', v_cat, v_result; END IF;
    END LOOP;
    IF (SELECT count(*) FROM finance.transactions) <> v_cnt0 THEN
      RAISE EXCEPTION 'FAIL fn_book_transaction [Kategorien]: trotz ok:false gebucht'; END IF;
    -- erlaubt bleiben other/fee/interest
    SELECT finance.fn_book_transaction(jsonb_build_object('account_id', v_acct_id, 'amount', '3',
      'direction', 'inflow', 'category', 'interest', 'transaction_date', CURRENT_DATE::text)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_transaction [interest erlaubt]: %', v_result; END IF;
  END;
  RAISE NOTICE 'PASS fn_book_transaction [9: strukturelle Kategorien + transfer -> ok:false, interest erlaubt]';

END $$;

ROLLBACK;
