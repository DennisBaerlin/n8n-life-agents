-- tests/db/finance/test_fn_crypto_holding.sql
-- Testet: fn_book_stock_buy akkumuliert Crypto-Positionen korrekt (isin=NULL, Symbol als Schlüssel).
-- Testet: partielle UNIQUE-Indizes verhindern Holding-Duplikate (ISIN-basiert + Symbol-basiert).
BEGIN;

DO $$
DECLARE
  v_result       JSONB;
  v_settle_id    INT;
  v_depot_id     INT;
  v_holding_id_1 INT;
  v_holding_id_2 INT;
  v_holding_count INT;
  v_got_shares   NUMERIC;
  v_got_avg      NUMERIC;
  v_got_bal      NUMERIC;
  -- Kauf 1: 0.5 BTC @ 60000, fee=0
  v_shares1      NUMERIC := 0.5;
  v_price1       NUMERIC := 60000;
  v_fee1         NUMERIC := 0;
  -- Kauf 2: 0.25 BTC @ 64000, fee=2
  v_shares2      NUMERIC := 0.25;
  v_price2       NUMERIC := 64000;
  v_fee2         NUMERIC := 2;
  v_exp_shares   NUMERIC;
  v_exp_avg      NUMERIC;
  v_exp_bal      NUMERIC;
BEGIN

  -- Voraussetzungen: Settlement + Crypto-Depot
  SELECT finance.fn_create_account(
    '{"name":"__test_crypto_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    jsonb_build_object(
      'name',           '__test_crypto_depot__',
      'account_type',   'crypto_depot',
      'account_holder', 'Test',
      'currency',       'EUR',
      'settlement_id',  v_settle_id
    )
  ) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- TEST 1a: Erster Crypto-Kauf (isin leer = kein ISIN für Crypto)
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            '',
      'symbol',          'BTC',
      'name',            'Bitcoin',
      'shares',          v_shares1,
      'price_per_share', v_price1,
      'order_fee',       v_fee1,
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;
  v_holding_id_1 := (v_result->>'holding_id')::int;

  IF v_holding_id_1 IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_crypto [1a]: holding_id NULL nach erstem Kauf';
  END IF;
  RAISE NOTICE 'PASS fn_crypto [1a]: erster BTC-Kauf, holding_id=%', v_holding_id_1;

  -- TEST 1b: Zweiter Crypto-Kauf gleicher Asset → SELBE Holding-Zeile, akkumulierte Shares
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            '',
      'symbol',          'BTC',
      'name',            'Bitcoin',
      'shares',          v_shares2,
      'price_per_share', v_price2,
      'order_fee',       v_fee2,
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;
  v_holding_id_2 := (v_result->>'holding_id')::int;

  -- KERN-ASSERT: beide Käufe liefern dieselbe holding_id
  IF v_holding_id_1 IS DISTINCT FROM v_holding_id_2 THEN
    RAISE EXCEPTION 'FAIL fn_crypto [1b]: zwei Käufe erzeugen verschiedene Holdings (% vs %) — Duplikat!',
      v_holding_id_1, v_holding_id_2;
  END IF;

  -- Assert: genau 1 Holding-Zeile für dieses Depot+Symbol
  SELECT COUNT(*) INTO v_holding_count
  FROM finance.depot_holdings
  WHERE account_id = v_depot_id AND symbol = 'BTC';

  IF v_holding_count <> 1 THEN
    RAISE EXCEPTION 'FAIL fn_crypto [1b]: erwartet 1 Holding, gefunden %', v_holding_count;
  END IF;

  -- Assert: Shares akkumuliert (0.5 + 0.25 = 0.75)
  v_exp_shares := v_shares1 + v_shares2;
  SELECT shares, average_purchase_price INTO v_got_shares, v_got_avg
  FROM finance.depot_holdings WHERE id = v_holding_id_1;

  IF v_got_shares IS DISTINCT FROM v_exp_shares THEN
    RAISE EXCEPTION 'FAIL fn_crypto [shares]: erwartet %, got %', v_exp_shares, v_got_shares;
  END IF;

  -- Assert: avg = (cost1 + cost2) / total_shares
  -- cost1 = 0.5*60000 + 0 = 30000; cost2 = 0.25*64000 + 2 = 16002; total = 46002 / 0.75
  v_exp_avg := (v_shares1 * v_price1 + v_fee1 + v_shares2 * v_price2 + v_fee2) / v_exp_shares;
  IF round(v_got_avg, 4) IS DISTINCT FROM round(v_exp_avg, 4) THEN
    RAISE EXCEPTION 'FAIL fn_crypto [avg]: erwartet %, got %', round(v_exp_avg, 4), round(v_got_avg, 4);
  END IF;

  -- Assert: Settlement-Saldo = -(cost1 + cost2)
  v_exp_bal := -(v_shares1 * v_price1 + v_fee1 + v_shares2 * v_price2 + v_fee2);
  SELECT finance.fn_get_balance(v_settle_id) INTO v_got_bal;
  IF v_got_bal IS DISTINCT FROM v_exp_bal THEN
    RAISE EXCEPTION 'FAIL fn_crypto [settle_bal]: erwartet %, got %', v_exp_bal, v_got_bal;
  END IF;

  RAISE NOTICE 'PASS fn_crypto [1b]: holding_id=%, shares=%, avg=%, settle_bal=%',
    v_holding_id_1, v_got_shares, round(v_got_avg, 2), v_got_bal;

  -- TEST 2: Zweite Crypto-Asset im selben Depot → ANDERE Holding-Zeile (Symbol ETH ≠ BTC)
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            '',
      'symbol',          'ETH',
      'name',            'Ethereum',
      'shares',          1,
      'price_per_share', 3000,
      'order_fee',       0,
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  IF (v_result->>'holding_id')::int = v_holding_id_1 THEN
    RAISE EXCEPTION 'FAIL fn_crypto [2]: ETH und BTC haben dieselbe holding_id % — falsch!', v_holding_id_1;
  END IF;

  SELECT COUNT(*) INTO v_holding_count
  FROM finance.depot_holdings WHERE account_id = v_depot_id;

  IF v_holding_count <> 2 THEN
    RAISE EXCEPTION 'FAIL fn_crypto [2]: erwartet 2 Holdings (BTC + ETH), gefunden %', v_holding_count;
  END IF;

  RAISE NOTICE 'PASS fn_crypto [2]: ETH korrekt als separate Holding angelegt';

  -- TEST 3: Reverse-Mismatch (ISIN-Aktie auf crypto_depot) -> {ok:false} (korrigierbar)
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id',        v_depot_id,
    'settlement_id',   v_settle_id,
    'isin',            'IE00B4L5Y983',
    'symbol',          'IUSQ',
    'name',            'iShares MSCI World',
    'shares',          5,
    'price_per_share', 100,
    'order_fee',       1,
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_crypto [3]: erwartet ok=false (ISIN auf crypto_depot), got %', v_result;
  END IF;
  IF v_result->>'depot_type' IS DISTINCT FROM 'crypto_depot' THEN
    RAISE EXCEPTION 'FAIL fn_crypto [3]: depot_type erwartet crypto_depot, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_crypto [3]: ISIN auf crypto_depot -> ok:false: %', v_result->>'reason';

END $$;

ROLLBACK;
