-- tests/db/finance/test_fn_book_dividend.sql
-- Testet fn_book_dividend: Dividende auf Settlement-Konto + holding_id gesetzt + shares=NULL (CHECK)
BEGIN;

DO $$
DECLARE
  v_result     JSONB;
  v_settle_id  INT;
  v_depot_id   INT;
  v_holding_id INT;
  v_tx_id      INT;
  v_balance    NUMERIC;
  v_div_amount NUMERIC := 42.50;
BEGIN

  -- Voraussetzungen: Settlement + Depot + Holding (via Kauf)
  SELECT finance.fn_create_account(
    '{"name":"__test_div_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    jsonb_build_object(
      'name',           '__test_div_depot__',
      'account_type',   'stocks_depot',
      'account_holder', 'Test',
      'currency',       'EUR',
      'settlement_id',  v_settle_id
    )
  ) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Holding über Kauf anlegen (fn_book_stock_buy legt Holding an falls nicht vorhanden)
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            'US1234567890',
      'symbol',          'DIV',
      'name',            'DivTest Corp',
      'shares',          '100',
      'price_per_share', '10',
      'order_fee',       '0',
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;
  v_holding_id := (v_result->>'holding_id')::int;

  -- Dividende buchen (auf Settlement-Konto, nicht auf Depot-Konto)
  SELECT finance.fn_book_dividend(
    jsonb_build_object(
      'account_id',       v_settle_id,
      'amount',           v_div_amount,
      'transaction_date', CURRENT_DATE::text,
      'holding_id',       v_holding_id,
      'description',      'Dividende DivTest Corp Q2/2024'
    )
  ) INTO v_result;

  IF NOT (v_result ? 'transaction_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_dividend: kein transaction_id, got %', v_result;
  END IF;
  v_tx_id := (v_result->>'transaction_id')::int;

  -- Assert: Txn mit category=dividend, amount positiv, holding_id gesetzt, shares=NULL
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_tx_id
      AND category = 'dividend'
      AND amount = v_div_amount
      AND holding_id = v_holding_id
      AND shares IS NULL  -- CHECK-Invariante: dividend darf kein shares-Feld haben
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_dividend: Txn-Felder nicht korrekt (id=%)', v_tx_id;
  END IF;

  -- Assert: Settlement-Balance hat die Dividende gutgeschrieben
  -- (nach Kauf: -1000; nach Dividende: -1000 + 42.50 = -957.50)
  SELECT finance.fn_get_balance(v_settle_id) INTO v_balance;
  IF v_balance IS DISTINCT FROM (-1000 + v_div_amount) THEN
    RAISE EXCEPTION 'FAIL fn_book_dividend: Balance sollte %, got %', (-1000 + v_div_amount), v_balance;
  END IF;

  -- Assert: Post-State-Vertrag — account_balance im Return
  IF (v_result->>'account_balance')::numeric IS DISTINCT FROM v_balance THEN
    RAISE EXCEPTION 'FAIL fn_book_dividend [return account_balance]: erwartet %, got %', v_balance, v_result->>'account_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_dividend: tx_id=%, amount=%, settle_bal=%',
    v_tx_id, v_div_amount, v_balance;

  -- Korrigierbar: amount <= 0 -> {ok:false} (kein RAISE)
  SELECT finance.fn_book_dividend(jsonb_build_object(
    'account_id', v_settle_id, 'amount', 0, 'transaction_date', CURRENT_DATE::text,
    'holding_id', v_holding_id, 'description', 'Nulldividende'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_dividend [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_dividend [amount<=0 -> ok:false]';

END $$;

ROLLBACK;
