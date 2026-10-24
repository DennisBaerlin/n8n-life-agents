-- tests/db/finance/test_fn_book_transfer.sql
-- Testet fn_book_transfer: zwei Transaktionen (Soll/Haben) + Balance-Trigger korrekt
BEGIN;

DO $$
DECLARE
  v_result    JSONB;
  v_from_id   INT;
  v_to_id     INT;
  v_amount    NUMERIC := 500;
  v_bal_from  NUMERIC;
  v_bal_to    NUMERIC;
  v_debit_id  INT;
  v_credit_id INT;
BEGIN

  -- Voraussetzungen: zwei Cash-Konten
  SELECT finance.fn_create_account(
    '{"name":"__test_tf_from__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_from_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    '{"name":"__test_tf_to__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_to_id := (v_result->>'account_id')::int;

  -- Transfer buchen
  SELECT finance.fn_book_transfer(
    jsonb_build_object(
      'from_account_id',   v_from_id,
      'to_account_id',     v_to_id,
      'amount',            v_amount,
      'transaction_date',  CURRENT_DATE::text,
      'from_account_name', '__test_tf_from__',
      'to_account_name',   '__test_tf_to__'
    )
  ) INTO v_result;

  IF NOT (v_result ? 'debit_tx_id') OR NOT (v_result ? 'credit_tx_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: debit_tx_id oder credit_tx_id fehlt, got %', v_result;
  END IF;
  v_debit_id  := (v_result->>'debit_tx_id')::int;
  v_credit_id := (v_result->>'credit_tx_id')::int;

  -- Assert: from-Balance = -amount (Trigger)
  SELECT finance.fn_get_balance(v_from_id) INTO v_bal_from;
  IF v_bal_from IS DISTINCT FROM -v_amount THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: from-Balance sollte %, got %', -v_amount, v_bal_from;
  END IF;

  -- Assert: to-Balance = +amount (Trigger)
  SELECT finance.fn_get_balance(v_to_id) INTO v_bal_to;
  IF v_bal_to IS DISTINCT FROM v_amount THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: to-Balance sollte %, got %', v_amount, v_bal_to;
  END IF;

  -- Assert: beide Txns haben category=transfer
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_debit_id AND category = 'transfer' AND amount = -v_amount
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: Debit-Txn nicht korrekt (id=%)', v_debit_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_credit_id AND category = 'transfer' AND amount = v_amount
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: Credit-Txn nicht korrekt (id=%)', v_credit_id;
  END IF;

  -- Assert: Post-State-Vertrag — from_balance/to_balance im Return
  IF (v_result->>'from_balance')::numeric IS DISTINCT FROM v_bal_from THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [return from_balance]: erwartet %, got %', v_bal_from, v_result->>'from_balance';
  END IF;
  IF (v_result->>'to_balance')::numeric IS DISTINCT FROM v_bal_to THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [return to_balance]: erwartet %, got %', v_bal_to, v_result->>'to_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_transfer: from_bal=%, to_bal=%, debit_id=%, credit_id=%',
    v_bal_from, v_bal_to, v_debit_id, v_credit_id;

  -- Korrigierbar: gleiches Konto -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from_id, 'to_account_id', v_from_id, 'amount', 100,
    'transaction_date', CURRENT_DATE::text, 'from_account_name', 'x', 'to_account_name', 'x'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [same account]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [same account -> ok:false]';

  -- Korrigierbar: amount <= 0 -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from_id, 'to_account_id', v_to_id, 'amount', 0,
    'transaction_date', CURRENT_DATE::text, 'from_account_name', 'a', 'to_account_name', 'b'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [amount<=0 -> ok:false]';

END $$;

-- ============================================================
-- Cross-Currency (Multi-Waehrung): je Bein in Native-Waehrung, to_amount Pflicht, fx_rate gespeichert.
-- ============================================================
DO $$
DECLARE
  v_result  JSONB;
  v_krw     INT;
  v_eur     INT;
  v_bal_krw NUMERIC;
  v_bal_eur NUMERIC;
  v_debit   INT;
  v_fx      NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_tf_krw__","account_type":"cash","currency":"KRW"}'::jsonb) INTO v_result;
  v_krw := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_tf_eur__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_eur := (v_result->>'account_id')::int;

  -- 1.450.000 KRW -> 1000 EUR (Nutzer bestaetigt beide Betraege)
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_krw, 'to_account_id', v_eur,
    'from_amount', 1450000, 'to_amount', 1000,
    'transaction_date', CURRENT_DATE::text,
    'from_account_name','__test_tf_krw__','to_account_name','__test_tf_eur__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL xccy transfer: erwartet ok=true, got %', v_result;
  END IF;
  v_debit := (v_result->>'debit_tx_id')::int;

  SELECT finance.fn_get_balance(v_krw) INTO v_bal_krw;
  SELECT finance.fn_get_balance(v_eur) INTO v_bal_eur;
  IF v_bal_krw IS DISTINCT FROM -1450000 THEN RAISE EXCEPTION 'FAIL xccy: KRW-Saldo % erwartet -1450000', v_bal_krw; END IF;
  IF v_bal_eur IS DISTINCT FROM 1000      THEN RAISE EXCEPTION 'FAIL xccy: EUR-Saldo % erwartet 1000', v_bal_eur; END IF;

  -- Assert: Post-State-Vertrag — native Salden beider Beine im Return (Cross-Currency)
  IF (v_result->>'from_balance')::numeric IS DISTINCT FROM v_bal_krw THEN
    RAISE EXCEPTION 'FAIL xccy [return from_balance]: erwartet %, got %', v_bal_krw, v_result->>'from_balance';
  END IF;
  IF (v_result->>'to_balance')::numeric IS DISTINCT FROM v_bal_eur THEN
    RAISE EXCEPTION 'FAIL xccy [return to_balance]: erwartet %, got %', v_bal_eur, v_result->>'to_balance';
  END IF;

  SELECT fx_rate INTO v_fx FROM finance.transactions WHERE id = v_debit;
  IF v_fx IS DISTINCT FROM ROUND(1000.0/1450000.0, 10) THEN
    RAISE EXCEPTION 'FAIL xccy: fx_rate % erwartet %', v_fx, ROUND(1000.0/1450000.0, 10);
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [cross-currency KRW->EUR]';

  -- Cross-Currency ohne to_amount -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_krw, 'to_account_id', v_eur, 'from_amount', 500000,
    'transaction_date', CURRENT_DATE::text,
    'from_account_name','__test_tf_krw__','to_account_name','__test_tf_eur__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL xccy [missing to_amount]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [cross-currency ohne to_amount -> ok:false]';
END $$;

-- ============================================================
-- WS-C2 Reserve-Waechter: ein Transfer raus aus einem Reserve-haltenden Konto drueckt dessen Saldo unter die
-- getaggte Reserve -> fn faltet reserve_breach NUR fuers Soll-(from-)Bein (das Haben-Bein erhoeht das Zielkonto).
-- ============================================================
DO $$
DECLARE
  v_result JSONB; v_from INT; v_to INT; v_goal INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__tf_rb_from__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result; v_from := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__tf_rb_to__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result; v_to := (v_result->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tf_rb_goal__', 9000, current_date + 365, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_from, 600, current_date - 10, 'transfer', v_goal, gen_random_uuid());   -- Reserve auf dem Quell-Konto: Saldo 600, reserviert 600

  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from, 'to_account_id', v_to, 'amount', 500,
    'transaction_date', CURRENT_DATE::text, 'from_account_name','__tf_rb_from__','to_account_name','__tf_rb_to__'
  )) INTO v_result;
  -- from-Saldo 100 < reserviert 600 -> reserve_breach fuers from-Konto, shortfall 500.
  IF NOT (v_result ? 'reserve_breach') OR (v_result->'reserve_breach'->>'account_id')::int IS DISTINCT FROM v_from
     OR (v_result->'reserve_breach'->>'shortfall')::numeric IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [reserve_breach]: erwartet reserve_breach fuers from-Konto shortfall 500, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [reserve_breach: Transfer raus aus Reserve-Konto -> from-Breach shortfall 500]';
END $$;

ROLLBACK;
