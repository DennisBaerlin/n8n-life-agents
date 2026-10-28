-- tests/db/finance/test_fn_book_stock_buy.sql
-- Testet fn_book_stock_buy: Holding anlegen + Kauf-Txn + Trigger für shares/avg_price/balance
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_result      JSONB;
  v_settle_id   INT;
  v_depot_id    INT;
  v_holding_id  INT;
  v_shares      NUMERIC := 10;
  v_price       NUMERIC := 80;
  v_fee         NUMERIC := 5;
  v_exp_avg     NUMERIC;
  v_exp_bal     NUMERIC;
  v_got_shares  NUMERIC;
  v_got_avg     NUMERIC;
  v_got_bal     NUMERIC;
BEGIN

  -- Voraussetzungen: Settlement-Konto + Depot
  SELECT finance.fn_create_account(
    '{"name":"__test_buy_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    jsonb_build_object(
      'name',           '__test_buy_depot__',
      'account_type',   'stocks_depot',
      'account_holder', 'Test',
      'currency',       'EUR',
      'settlement_id',  v_settle_id
    )
  ) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Aktien kaufen
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            'IE00B4L5Y983',
      'symbol',          'IUSQ',
      'name',            'iShares MSCI World UCITS ETF',
      'shares',          v_shares,
      'price_per_share', v_price,
      'order_fee',       v_fee,
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  IF NOT (v_result ? 'holding_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy: kein holding_id in Result, got %', v_result;
  END IF;
  v_holding_id := (v_result->>'holding_id')::int;

  -- Erwartete Werte
  v_exp_avg := (v_shares * v_price + v_fee) / v_shares;  -- = 80.5
  v_exp_bal := -(v_shares * v_price + v_fee);             -- = -805

  -- Assert: shares via Trigger
  SELECT shares, average_purchase_price
  INTO v_got_shares, v_got_avg
  FROM finance.depot_holdings WHERE id = v_holding_id;

  IF v_got_shares IS DISTINCT FROM v_shares THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [shares]: erwartet %, got %', v_shares, v_got_shares;
  END IF;

  -- Assert: average_purchase_price via Trigger (Gebühr gefaltet)
  IF v_got_avg IS DISTINCT FROM v_exp_avg THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [avg_price]: erwartet %, got %', v_exp_avg, v_got_avg;
  END IF;

  -- Assert: Settlement-Balance (Kauf kostet shares*price + fee)
  SELECT finance.fn_get_balance(v_settle_id) INTO v_got_bal;
  IF v_got_bal IS DISTINCT FROM v_exp_bal THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [settlement_balance]: erwartet %, got %', v_exp_bal, v_got_bal;
  END IF;

  -- Assert: order_fee separat gespeichert (Steuer/Reporting)
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE holding_id = v_holding_id AND category = 'buy' AND order_fee = v_fee
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy: order_fee nicht separat gespeichert';
  END IF;

  -- Assert: Post-State-Vertrag — settlement_balance/total_shares/avg_purchase_price im Return-Payload
  IF (v_result->>'settlement_balance')::numeric IS DISTINCT FROM v_exp_bal THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [return settlement_balance]: erwartet %, got %', v_exp_bal, v_result->>'settlement_balance';
  END IF;
  IF (v_result->>'total_shares')::numeric IS DISTINCT FROM v_shares THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [return total_shares]: erwartet %, got %', v_shares, v_result->>'total_shares';
  END IF;
  IF (v_result->>'avg_purchase_price')::numeric IS DISTINCT FROM v_exp_avg THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [return avg_purchase_price]: erwartet %, got %', v_exp_avg, v_result->>'avg_purchase_price';
  END IF;

  RAISE NOTICE 'PASS fn_book_stock_buy: holding_id=%, shares=%, avg=%, settle_bal=%',
    v_holding_id, v_got_shares, v_got_avg, v_got_bal;

  -- TEST 2: Zweiter Kauf → avg muss korrekt nachjustiert werden
  SELECT finance.fn_book_stock_buy(
    jsonb_build_object(
      'depot_id',        v_depot_id,
      'settlement_id',   v_settle_id,
      'isin',            'IE00B4L5Y983',
      'symbol',          'IUSQ',
      'name',            'iShares MSCI World UCITS ETF',
      'shares',          '5',
      'price_per_share', '90',
      'order_fee',       '0',
      'transaction_date', CURRENT_DATE::text
    )
  ) INTO v_result;

  -- Nach 2. Kauf: total shares = 15, avg = (805 + 450) / 15 = 83.67 (gerundet)
  SELECT shares, average_purchase_price INTO v_got_shares, v_got_avg
  FROM finance.depot_holdings WHERE id = v_holding_id;

  IF v_got_shares IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [2. Kauf shares]: erwartet 15, got %', v_got_shares;
  END IF;

  IF round(v_got_avg, 2) IS DISTINCT FROM round((805::numeric + 450::numeric) / 15, 2) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [2. Kauf avg]: erwartet %, got %',
      round((805::numeric + 450::numeric) / 15, 2), round(v_got_avg, 2);
  END IF;

  -- Assert: Post-State im Return nach 2. Kauf (kumuliert: shares=15, settle_bal=-1255)
  IF (v_result->>'total_shares')::numeric IS DISTINCT FROM 15 THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [2. Kauf return total_shares]: erwartet 15, got %', v_result->>'total_shares';
  END IF;
  IF (v_result->>'settlement_balance')::numeric IS DISTINCT FROM -1255 THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [2. Kauf return settlement_balance]: erwartet -1255, got %', v_result->>'settlement_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_stock_buy [2. Kauf]: shares=%, avg=%', v_got_shares, round(v_got_avg, 2);

  -- TEST 3: Depot-Typ-Mismatch (Crypto ohne ISIN auf stocks_depot) -> {ok:false} (korrigierbar)
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id',        v_depot_id,
    'settlement_id',   v_settle_id,
    'isin',            '',
    'symbol',          'BTC',
    'name',            'Bitcoin',
    'shares',          0.1,
    'price_per_share', 60000,
    'order_fee',       0,
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [depot_type_mismatch]: erwartet ok=false, got %', v_result;
  END IF;
  IF v_result->>'depot_type' IS DISTINCT FROM 'stocks_depot' THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [depot_type_mismatch]: depot_type erwartet stocks_depot, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [depot_type_mismatch -> ok:false]: %', v_result->>'reason';

  -- TEST 4: shares <= 0 -> {ok:false} (korrigierbar, analog sell)
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot_id, 'settlement_id', v_settle_id,
    'isin', 'IE00B4L5Y983', 'symbol', 'IUSQ', 'name', 'iShares MSCI World',
    'shares', 0, 'price_per_share', 100, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [shares<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [shares<=0 -> ok:false]';

  -- TEST 5: price <= 0 -> {ok:false}
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot_id, 'settlement_id', v_settle_id,
    'isin', 'IE00B4L5Y983', 'symbol', 'IUSQ', 'name', 'iShares MSCI World',
    'shares', 5, 'price_per_share', 0, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [price<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [price<=0 -> ok:false]';

  -- TEST 6 (WS2b): asset_class-Auto-Tag wird beim ANLEGEN der Holding gesetzt
  DECLARE v_tag TEXT; v_h6 INT; BEGIN
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin', 'IE00BK5BQT80', 'symbol', 'VWCE', 'name', 'Vanguard FTSE All-World',
      'shares', 3, 'price_per_share', 100, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
      'asset_class', 'sp500'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [asset_class ok]: %', v_result; END IF;
    v_h6 := (v_result->>'holding_id')::int;
    SELECT asset_class INTO v_tag FROM finance.depot_holdings WHERE id = v_h6;
    IF v_tag IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [asset_class set]: erwartet sp500, got %', v_tag; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [asset_class Auto-Tag beim Anlegen gesetzt]';

    -- 6b: ein zweiter Kauf derselben Position ueberschreibt den Tag NICHT (Korrektur nur via set_holding)
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin', 'IE00BK5BQT80', 'symbol', 'VWCE', 'name', 'Vanguard FTSE All-World',
      'shares', 2, 'price_per_share', 110, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
      'asset_class', 'gold'
    )) INTO v_result;
    SELECT asset_class INTO v_tag FROM finance.depot_holdings WHERE id = v_h6;
    IF v_tag IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Tag ueberschrieben]: erwartet sp500 unveraendert, got %', v_tag; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [wiederholter Kauf ueberschreibt asset_class nicht]';
  END;

  -- TEST 7 (WS2b): ungueltiges asset_class-Format -> {ok:false}, kein Write
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot_id, 'settlement_id', v_settle_id,
    'isin', 'IE00B0M62Q58', 'symbol', 'VWRL2', 'name', 'Test',
    'shares', 1, 'price_per_share', 50, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
    'asset_class', 'S&P 500'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [asset_class bad format]: erwartet ok=false, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.depot_holdings WHERE symbol = 'VWRL2') THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [asset_class bad format]: Holding wurde trotz ok=false angelegt';
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [ungueltiges asset_class-Format -> ok:false, kein Write]';

  -- TEST 8 (Phase M): provider_symbol + quote_currency beim ANLEGEN gesetzt; Wiederkauf ueberschreibt nicht.
  DECLARE v_ps TEXT; v_qc CHAR(3); v_h8 INT; BEGIN
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin', 'IE00BFMXXD54', 'symbol', 'VUSA', 'name', 'Vanguard S&P 500',
      'shares', 4, 'price_per_share', 80, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
      'provider_symbol', 'VUSA.UK', 'quote_currency', 'USD'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [provider/quote ok]: %', v_result; END IF;
    v_h8 := (v_result->>'holding_id')::int;
    SELECT provider_symbol, quote_currency INTO v_ps, v_qc FROM finance.depot_holdings WHERE id = v_h8;
    IF v_ps IS DISTINCT FROM 'VUSA.UK' OR v_qc IS DISTINCT FROM 'USD' THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [provider/quote set]: provider_symbol=% quote_currency=%', v_ps, v_qc; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [provider_symbol + quote_currency beim Anlegen gesetzt]';

    -- 8b: Wiederkauf mit anderen Werten ueberschreibt provider_symbol/quote_currency NICHT (wie asset_class)
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin', 'IE00BFMXXD54', 'symbol', 'VUSA', 'name', 'Vanguard S&P 500',
      'shares', 2, 'price_per_share', 90, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
      'provider_symbol', 'VUSA.DE', 'quote_currency', 'EUR'
    )) INTO v_result;
    SELECT provider_symbol, quote_currency INTO v_ps, v_qc FROM finance.depot_holdings WHERE id = v_h8;
    IF v_ps IS DISTINCT FROM 'VUSA.UK' OR v_qc IS DISTINCT FROM 'USD' THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [provider/quote ueberschrieben]: provider_symbol=% quote_currency=%', v_ps, v_qc; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [Wiederkauf ueberschreibt provider_symbol/quote_currency nicht]';
  END;

  -- TEST 9 (WP-1 Crash-Schutz): quote_currency in KLEINSCHREIBUNG ('usd') -> normalisiert 'USD', Holding
  -- angelegt mit quote_currency='USD' (VOR dem Fix: {ok:false} = Ablehnung statt Normalisierung).
  DECLARE v_qc9 CHAR(3); v_h9 INT; BEGIN
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin', 'IE00BADQC999', 'symbol', 'LCUSD', 'name', 'Lowercase Quote Ccy',
      'shares', 1, 'price_per_share', 50, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
      'quote_currency', 'usd'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [quote_currency lowercase]: erwartet ok=true (normalisiert), got %', v_result; END IF;
    v_h9 := (v_result->>'holding_id')::int;
    SELECT quote_currency INTO v_qc9 FROM finance.depot_holdings WHERE id = v_h9;
    IF v_qc9 IS DISTINCT FROM 'USD' THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [quote_currency lowercase]: erwartet normalisiert USD, got %', v_qc9; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [lowercase quote_currency usd -> normalisiert USD]';
  END;

  -- TEST 9b (WP-1): echt-ungueltiger quote_currency-Code ('DOLLAR') -> {ok:false}, kein Write.
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot_id, 'settlement_id', v_settle_id,
    'isin', 'IE00BADQC998', 'symbol', 'BADQC', 'name', 'Bad Quote Ccy',
    'shares', 1, 'price_per_share', 50, 'order_fee', 0, 'transaction_date', CURRENT_DATE::text,
    'quote_currency', 'DOLLAR'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [quote_currency bad format]: erwartet ok=false, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.depot_holdings WHERE symbol = 'BADQC') THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_buy [quote_currency bad format]: Holding wurde trotz ok=false angelegt';
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_buy [ungueltige quote_currency DOLLAR -> ok:false, kein Write]';

  -- ============================================================
  -- TEST 10-13 (WS-B Stufe 2, Vertragsaenderung Sparziel-Zweckbindung 2026-10-27): ein goal-verknuepfter Sparplan-Kauf
  --   schreibt Journal-Zeilen (kind sparplan_buy, source_tx_id = Kauf): Depot +X und — soweit Ziel-Geld auf dem
  --   Verrechnungskonto liegt — Verrechnungskonto -c (c = min(Anteil, X)). Der Kauf selbst traegt KEIN Tag mehr.
  --   Ziel-Geld wird nur umgeschichtet (konserviert), frisches Geld (X - c) zaehlt als neu gespart.
  --   Manueller Kauf (kein rp) -> KEINE Wirkung.
  -- ============================================================
  DECLARE
    v_goal_id    INT;
    v_plan_rp    INT;
    v_curr       NUMERIC;
    v_buy_tx     INT;
    v_jrnl_cnt   INT;
    v_jrnl_delta NUMERIC;
    v_jrnl_acct  INT;
    v_jrnl_kind  TEXT;
    v_jrnl_src   INT;
    v_tag        INT;
    v_cnt_before INT;
    v_crypto_dep INT;
    v_crypto_rp  INT;
  BEGIN
    -- Sparziel (Cash-Rate auf dem Settlement-Konto; fuer den Journal-Test nicht zwingend genutzt,
    -- aber fn_create_savings_goal legt sie an).
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name',                 '__test_buy_goal__',
      'target_amount',        5000,
      'target_date',          (CURRENT_DATE + 365)::text,
      'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',           v_settle_id,
      'schedule_day_of_month', 1,
      'first_payment_date',   (CURRENT_DATE + 5)::text
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL fn_create_savings_goal: %', v_result; END IF;
    v_goal_id := (v_result->>'goal_id')::int;

    -- Sparplan auf dem Aktien-Depot (eigene recurring_payment auf dem Settlement-Konto).
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name',              '__test_buy_plan__',
      'depot_name',        '__test_buy_depot__',
      'isin',              'IE00B4L5Y983',
      'symbol',            'IUSQ',
      'security_name',     'iShares MSCI World',
      'amount',            50,
      'schedule_interval', 1,
      'schedule_unit',     'month',
      'first_payment_date', CURRENT_DATE::text
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan: %', v_result; END IF;
    v_plan_rp := (v_result->>'recurring_payment_id')::int;

    -- Sparplan dem Ziel zuordnen (Quellen-Verknuepfung).
    SELECT finance.fn_set_savings_goal(jsonb_build_object(
      'goal_id',                v_goal_id,
      'link_savings_plan_name', '__test_buy_plan__'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL link savings plan: %', v_result; END IF;

    -- Cash-Feed: +200 getaggt (simuliert das Reserve-Zufluss-Bein der Sparrate).
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id)
    VALUES (v_settle_id, 200, CURRENT_DATE, 'other', v_goal_id);

    SELECT current_amount INTO v_curr FROM finance.savings_goal_progress WHERE id = v_goal_id;
    IF v_curr IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'SETUP FAIL [baseline current_amount]: erwartet 200, got %', v_curr; END IF;

    -- TEST 10: goal-verknuepfter Kauf -> Cash-Tag + Journal-Zeile + Konservierung.
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id',        v_depot_id, 'settlement_id', v_settle_id,
      'isin',            'IE00B4L5Y983', 'symbol', 'IUSQ', 'name', 'iShares MSCI World',
      'shares',          0.5, 'price_per_share', 100, 'order_fee', 0,
      'transaction_date', CURRENT_DATE::text,
      'recurring_payment_id', v_plan_rp
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [sparplan_buy ok]: %', v_result; END IF;
    v_buy_tx := (v_result->>'buy_tx_id')::int;

    -- (a) der Kauf traegt kein Ziel-Tag mehr (die Umschichtung laeuft komplett im Journal)
    SELECT savings_goal_id INTO v_tag FROM finance.transactions WHERE id = v_buy_tx;
    IF v_tag IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [kein Kauf-Tag]: erwartet NULL, got %', v_tag; END IF;

    -- (b) Depot-Zeile +50 (sparplan_buy, source=buy_tx) + Verrechnungskonto-Zeile -50 (Ziel-Geld lag dort: 200 >= 50)
    SELECT count(*), min(delta_native), min(kind), min(source_tx_id)
      INTO v_jrnl_cnt, v_jrnl_delta, v_jrnl_kind, v_jrnl_src
      FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal_id AND account_id = v_depot_id;
    IF v_jrnl_cnt IS DISTINCT FROM 1 OR v_jrnl_delta IS DISTINCT FROM 50 OR v_jrnl_kind IS DISTINCT FROM 'sparplan_buy'
       OR v_jrnl_src IS DISTINCT FROM v_buy_tx THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Depot-Zeile]: cnt % delta % kind % src %', v_jrnl_cnt, v_jrnl_delta, v_jrnl_kind, v_jrnl_src; END IF;
    SELECT count(*), min(delta_native) INTO v_jrnl_cnt, v_jrnl_delta
      FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal_id AND account_id = v_settle_id AND source_tx_id = v_buy_tx;
    IF v_jrnl_cnt IS DISTINCT FROM 1 OR v_jrnl_delta IS DISTINCT FROM -50 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Verrechnungskonto-Zeile]: cnt % delta %', v_jrnl_cnt, v_jrnl_delta; END IF;

    -- (c) KONSERVIERUNG: Ziel-Geld umgeschichtet -> current_amount = 200 - 50 + 50 = 200 UNVERAENDERT
    SELECT current_amount INTO v_curr FROM finance.savings_goal_progress WHERE id = v_goal_id;
    IF v_curr IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Konservierung]: current_amount erwartet 200 (nur Feed), got % (Kauf doppelt gezaehlt?)', v_curr; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [sparplan_buy aus Ziel-Geld: Depot +50, Verrechnungskonto -50, Konservierung 200]';

    -- TEST 11: manueller Kauf (kein recurring_payment_id) -> KEINE Wirkung (kein Tag, kein Journal).
    SELECT count(*) INTO v_cnt_before FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal_id;
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id',        v_depot_id, 'settlement_id', v_settle_id,
      'isin',            'IE00B4L5Y983', 'symbol', 'IUSQ', 'name', 'iShares MSCI World',
      'shares',          1, 'price_per_share', 100, 'order_fee', 0,
      'transaction_date', CURRENT_DATE::text
    )) INTO v_result;
    v_buy_tx := (v_result->>'buy_tx_id')::int;
    SELECT savings_goal_id INTO v_tag FROM finance.transactions WHERE id = v_buy_tx;
    IF v_tag IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [manueller Kauf Tag]: erwartet NULL, got %', v_tag; END IF;
    SELECT count(*) INTO v_jrnl_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal_id;
    IF v_jrnl_cnt IS DISTINCT FROM v_cnt_before THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [manueller Kauf Journal]: Zeilenzahl erwartet % (unveraendert), got %', v_cnt_before, v_jrnl_cnt; END IF;
    -- current_amount unveraendert (ein untagged Cash-Bein zaehlt nicht zum Ziel)
    SELECT current_amount INTO v_curr FROM finance.savings_goal_progress WHERE id = v_goal_id;
    IF v_curr IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [manueller Kauf Konservierung]: current_amount erwartet 200, got %', v_curr; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [WS-B2 manueller Kauf -> keine Reserve-Wirkung]';

    -- TEST 12: Gebuehr im Cost-Basis -> delta_native = shares*price + fee (volle Cash-Abfluss-Magnitude).
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id',        v_depot_id, 'settlement_id', v_settle_id,
      'isin',            'IE00B4L5Y983', 'symbol', 'IUSQ', 'name', 'iShares MSCI World',
      'shares',          1, 'price_per_share', 100, 'order_fee', 5,
      'transaction_date', (CURRENT_DATE - 1)::text,   -- WP-1: distinktes Datum (Sparplan-Kauf ist je (rp,date) idempotent)
      'recurring_payment_id', v_plan_rp
    )) INTO v_result;
    v_buy_tx := (v_result->>'buy_tx_id')::int;
    SELECT delta_native INTO v_jrnl_delta FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_buy_tx AND account_id = v_depot_id;
    IF v_jrnl_delta IS DISTINCT FROM 105 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Journal-delta inkl. Gebuehr]: erwartet 105 (100+5), got %', v_jrnl_delta; END IF;
    -- Konservierung haelt auch mit Gebuehr (Gebuehr verlaesst Cash und betritt Depot-Reserve symmetrisch).
    SELECT current_amount INTO v_curr FROM finance.savings_goal_progress WHERE id = v_goal_id;
    IF v_curr IS DISTINCT FROM 200 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [Konservierung inkl. Gebuehr]: current_amount erwartet 200, got %', v_curr; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [WS-B2 Gebuehr im Journal-delta (105) + Konservierung]';

    -- TEST 13: FX-Krypto-Fall — goal-verknuepfter Krypto-Sparplan (kein ISIN) -> Journal aufs Krypto-Depot.
    SELECT finance.fn_create_account(jsonb_build_object(
      'name', '__test_buy_crypto_depot__', 'account_type', 'crypto_depot',
      'account_holder', 'Test', 'currency', 'EUR', 'settlement_id', v_settle_id
    )) INTO v_result;
    v_crypto_dep := (v_result->>'account_id')::int;

    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name', '__test_buy_crypto_plan__', 'depot_name', '__test_buy_crypto_depot__',
      'symbol', 'BTC', 'security_name', 'Bitcoin', 'amount', 500,
      'schedule_interval', 1, 'schedule_unit', 'month', 'first_payment_date', CURRENT_DATE::text
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL crypto savings plan: %', v_result; END IF;
    v_crypto_rp := (v_result->>'recurring_payment_id')::int;

    SELECT finance.fn_set_savings_goal(jsonb_build_object(
      'goal_id', v_goal_id, 'link_savings_plan_name', '__test_buy_crypto_plan__'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL link crypto plan: %', v_result; END IF;

    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id',        v_crypto_dep, 'settlement_id', v_settle_id,
      'isin',            '', 'symbol', 'BTC', 'name', 'Bitcoin',
      'shares',          0.01, 'price_per_share', 50000, 'order_fee', 0,
      'transaction_date', CURRENT_DATE::text,
      'recurring_payment_id', v_crypto_rp
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [crypto sparplan_buy ok]: %', v_result; END IF;
    v_buy_tx := (v_result->>'buy_tx_id')::int;
    SELECT delta_native INTO v_jrnl_delta
      FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_buy_tx AND account_id = v_crypto_dep;
    IF v_jrnl_delta IS DISTINCT FROM 500 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [crypto Journal-delta]: erwartet 500 (0.01*50000), got %', v_jrnl_delta; END IF;
    -- TEILWEISE aus Ziel-Geld: auf dem Verrechnungskonto liegen nur noch 200-50-105 = 45 des Ziels -> -45 dort,
    -- 455 frisches Geld -> current_amount 200 + 455 = 655.
    SELECT delta_native INTO v_jrnl_delta
      FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_buy_tx AND account_id = v_settle_id;
    IF v_jrnl_delta IS DISTINCT FROM -45 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [crypto teilweise]: Verrechnungskonto-Zeile erwartet -45, got %', v_jrnl_delta; END IF;
    SELECT current_amount INTO v_curr FROM finance.savings_goal_progress WHERE id = v_goal_id;
    IF v_curr IS DISTINCT FROM 655 THEN
      RAISE EXCEPTION 'FAIL fn_book_stock_buy [crypto teilweise frisch]: current_amount erwartet 655, got %', v_curr; END IF;
    RAISE NOTICE 'PASS fn_book_stock_buy [Krypto-Kauf: 45 umgeschichtet, 455 frisch -> 655]';
  END;

  -- ============================================================
  -- TEST 14 (Phase L WS-6): null_tag-Fallback-Note, wenn die RESULTIERENDE Holding ungetaggt ist. Basiert auf
  --   dem END-Zustand (asset_class der Holding), NICHT auf dem Input -> ein Re-Buy einer bereits getaggten
  --   Position nagt NICHT.
  -- ============================================================
  DECLARE v_h14 INT; BEGIN
    -- (14a) Neuer manueller Kauf OHNE asset_class -> Holding untagged -> null_tag-Note im {ok:true}
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin','IE00NT000001','symbol','NTAG','name','Untagged ETF',
      'shares',1,'price_per_share',100,'order_fee',0,'transaction_date', CURRENT_DATE::text)) INTO v_result;
    IF NOT (v_result ? 'null_tag') OR COALESCE(v_result->'null_tag'->>'note','') = '' THEN
      RAISE EXCEPTION 'FAIL [14a]: kein null_tag-Fold mit note bei ungetaggter neuer Position, got %', v_result; END IF;
    RAISE NOTICE 'PASS [14a WS-6: neue untagged Position -> null_tag-Fallback-Note]';

    -- (14b) Neuer manueller Kauf MIT asset_class -> Holding getaggt -> KEINE Note
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin','IE00TG000001','symbol','TG14','name','Tagged ETF',
      'shares',1,'price_per_share',100,'order_fee',0,'transaction_date', CURRENT_DATE::text,
      'asset_class','sp500')) INTO v_result;
    v_h14 := (v_result->>'holding_id')::int;
    IF v_result ? 'null_tag' THEN
      RAISE EXCEPTION 'FAIL [14b]: null_tag-Fold trotz gesetzter asset_class, got %', v_result; END IF;
    RAISE NOTICE 'PASS [14b WS-6: getaggte neue Position -> keine Note]';

    -- (14c) Re-Buy DERSELBEN getaggten Position OHNE asset_class -> Holding bleibt getaggt -> KEINE Note
    --   (Note haengt am END-Zustand, nicht am Input -> kein falsches Nagen beim Nachkauf).
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin','IE00TG000001','symbol','TG14','name','Tagged ETF',
      'shares',1,'price_per_share',110,'order_fee',0,'transaction_date', CURRENT_DATE::text)) INTO v_result;
    IF v_result ? 'null_tag' THEN
      RAISE EXCEPTION 'FAIL [14c]: null_tag-Fold beim Re-Buy einer bereits getaggten Position (input NULL), got %', v_result; END IF;
    RAISE NOTICE 'PASS [14c WS-6: Re-Buy getaggter Position (input NULL) -> keine Note]';
  END;

  -- ============================================================
  -- TEST 15 (WP-3b): FREMDWAEHRUNG — goal-verknuepfter Kauf auf einem KRW-Depot (KRW-Settlement). Der Reserve-
  --   Journal-Eintrag speichert den ROHEN KRW-Betrag + currency='KRW' + value_date (KEIN fn_to_eur am Insert ->
  --   kein NULL-Crash); die VIEW konvertiert nach EUR. depot_reserve_status.reserved = 1000 EUR (NICHT roh
  --   1450000), current_amount bleibt konserviert (Cash-Bein und Depot-Journal kuerzen sich in EUR).
  -- ============================================================
  DECLARE
    v_krw_settle INT; v_krw_depot INT; v_krw_goal INT; v_krw_rp INT;
    v_kbuy INT; v_dn NUMERIC; v_dccy CHAR(3); v_vd DATE; v_reserved NUMERIC; v_kcur NUMERIC;
  BEGIN
    INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of)
      VALUES ('EUR','KRW', 1450, current_date) ON CONFLICT (base_currency, quote_currency, as_of) DO NOTHING;  -- 1 EUR = 1450 KRW

    INSERT INTO finance.accounts (name, account_type, currency, status)
      VALUES ('__krw_settle__','cash','KRW','active') RETURNING id INTO v_krw_settle;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__krw_depot__','crypto_depot','KRW','active', v_krw_settle) RETURNING id INTO v_krw_depot;

    INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
      VALUES ('__krw_goal__', 100000, current_date + 365, 'active') RETURNING id INTO v_krw_goal;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__krw_plan__','depot_name','__krw_depot__','symbol','BTC','security_name','Bitcoin',
      'amount', 1450000, 'schedule_interval',1,'schedule_unit','month','first_payment_date',CURRENT_DATE::text
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL krw plan: %', v_result; END IF;
    v_krw_rp := (v_result->>'recurring_payment_id')::int;
    SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_krw_goal, 'link_savings_plan_name','__krw_plan__')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL krw link: %', v_result; END IF;

    -- goal-verknuepfter KRW-Kauf: 1 BTC @ 1450000 KRW (KRW-Settlement == KRW-Depot -> Guard ok).
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_krw_depot, 'settlement_id', v_krw_settle,
      'isin','', 'symbol','BTC','name','Bitcoin',
      'shares',1,'price_per_share',1450000,'order_fee',0,'transaction_date', CURRENT_DATE::text,
      'recurring_payment_id', v_krw_rp)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [15 krw buy]: %', v_result; END IF;
    v_kbuy := (v_result->>'buy_tx_id')::int;

    -- (a) Journal-Zeile: ROHER KRW-Betrag + currency='KRW' + value_date=heute (kein fn_to_eur am Insert).
    SELECT delta_native, currency, value_date INTO v_dn, v_dccy, v_vd
      FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_kbuy;
    IF v_dn IS DISTINCT FROM 1450000 THEN RAISE EXCEPTION 'FAIL [15 delta_native]: erwartet roh 1450000 KRW, got %', v_dn; END IF;
    IF v_dccy IS DISTINCT FROM 'KRW' THEN RAISE EXCEPTION 'FAIL [15 currency]: erwartet KRW, got %', v_dccy; END IF;
    IF v_vd IS DISTINCT FROM CURRENT_DATE THEN RAISE EXCEPTION 'FAIL [15 value_date]: erwartet heute, got %', v_vd; END IF;

    -- (b) VIEW konvertiert nach EUR: reserved = 1450000/1450 = 1000 EUR (NICHT der rohe KRW-Betrag).
    SELECT reserved INTO v_reserved FROM finance.depot_reserve_status WHERE account_id = v_krw_depot;
    IF v_reserved IS DISTINCT FROM 1000 THEN RAISE EXCEPTION 'FAIL [15 reserved EUR]: erwartet 1000 EUR (1450000 KRW / 1450), got % (View nicht konvertiert?)', v_reserved; END IF;

    -- (c) FRISCHES GELD in EUR (2026-10-27): auf dem KRW-Verrechnungskonto lag kein Ziel-Geld -> keine Gegenzeile,
    --     der Kauf zaehlt voll: current_amount = 1000 EUR.
    SELECT current_amount INTO v_kcur FROM finance.savings_goal_progress WHERE id = v_krw_goal;
    IF v_kcur IS DISTINCT FROM 1000 THEN RAISE EXCEPTION 'FAIL [15 frisch]: erwartet 1000 EUR (frisches Geld), got %', v_kcur; END IF;
    RAISE NOTICE 'PASS [15 WP-3b: KRW-Kauf -> delta_native roh KRW + currency + EUR-Umrechnung in der View (reserved 1000), frisch +1000]';

    -- (d) value_date FOLGT dem transaction_date (nicht hardcoded CURRENT_DATE) — RUECKDATIERTER Kauf.
    DECLARE v_bkbuy INT; v_bkvd DATE; BEGIN
      SELECT finance.fn_book_stock_buy(jsonb_build_object(
        'depot_id', v_krw_depot, 'settlement_id', v_krw_settle,
        'isin','', 'symbol','BTC','name','Bitcoin',
        'shares',1,'price_per_share',1450000,'order_fee',0,
        'transaction_date', (CURRENT_DATE - 7)::text,   -- rueckdatiert
        'recurring_payment_id', v_krw_rp)) INTO v_result;
      IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [15d backdated buy]: %', v_result; END IF;
      v_bkbuy := (v_result->>'buy_tx_id')::int;
      SELECT value_date INTO v_bkvd FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_bkbuy;
      IF v_bkvd IS DISTINCT FROM (CURRENT_DATE - 7) THEN
        RAISE EXCEPTION 'FAIL [15d value_date]: erwartet Kaufdatum (heute-7), got % (value_date hardcoded CURRENT_DATE?)', v_bkvd; END IF;
      RAISE NOTICE 'PASS [15d WP-3b: value_date folgt dem transaction_date (rueckdatierter Kauf -> Kurs deterministisch gepinnt)]';
    END;
  END;

  -- ============================================================
  -- TEST 16 (WP-3b Guard): goal-verknuepfter Kauf mit Settlement-Waehrung != Depot-Waehrung -> {ok:false},
  --   kein partieller Write (Cross-Currency-Settlement out-of-scope; sonst kuerzen sich die Legs in EUR nicht).
  -- ============================================================
  DECLARE
    v_x_depot INT; v_x_goal INT; v_x_rp INT;
  BEGIN
    -- KRW-Depot, aber das EUR-Settlement-Konto von oben (v_settle_id) -> Waehrungs-Mismatch.
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__xccy_depot__','crypto_depot','KRW','active', v_settle_id) RETURNING id INTO v_x_depot;
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
      VALUES ('__xccy_goal__', 5000, current_date + 365, 'active') RETURNING id INTO v_x_goal;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__xccy_plan__','depot_name','__xccy_depot__','symbol','ETH','security_name','Ether',
      'amount', 100, 'schedule_interval',1,'schedule_unit','month','first_payment_date',CURRENT_DATE::text
    )) INTO v_result;
    v_x_rp := (v_result->>'recurring_payment_id')::int;
    SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_x_goal, 'link_savings_plan_name','__xccy_plan__')) INTO v_result;

    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_x_depot, 'settlement_id', v_settle_id,   -- EUR-Settlement != KRW-Depot
      'isin','', 'symbol','ETH','name','Ether',
      'shares',1,'price_per_share',100,'order_fee',0,'transaction_date', CURRENT_DATE::text,
      'recurring_payment_id', v_x_rp)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [16 guard]: erwartet ok=false (Cross-Currency-Settlement), got %', v_result; END IF;
    IF v_result->>'reason' NOT LIKE '%Cross-currency%' THEN
      RAISE EXCEPTION 'FAIL [16 guard reason]: erwartet Cross-currency-Hinweis, got %', v_result->>'reason'; END IF;
    IF EXISTS (SELECT 1 FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_x_goal) THEN
      RAISE EXCEPTION 'FAIL [16 guard]: Journal-Zeile trotz {ok:false} angelegt'; END IF;
    IF EXISTS (SELECT 1 FROM finance.depot_holdings WHERE account_id = v_x_depot) THEN
      RAISE EXCEPTION 'FAIL [16 guard]: Holding trotz {ok:false} angelegt (partieller Write)'; END IF;
    RAISE NOTICE 'PASS [16 WP-3b Guard: Settlement != Depot-Waehrung -> {ok:false}, kein partieller Write]';
  END;

END $$;

-- ============================================================
-- Bestandsuebernahme (existing_position, Eindeutigkeit 2026-10-21): eine bereits gehaltene Position
-- erfassen, OHNE den (schon heutigen) Saldo des Verrechnungskontos zu veraendern.
-- ============================================================
DO $$
DECLARE
  v_res     JSONB;
  v_settle  INT;
  v_depot   INT;
  v_buy     INT;
  v_hold    INT;
  v_group   UUID;
  v_bal     NUMERIC;
  v_avg     NUMERIC;
  v_ok      BOOLEAN;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_take_settle__","account_type":"cash","opening_balance":2500}'::jsonb)->>'account_id')::int
    INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_take_depot__','account_type','stocks_depot',
    'settlement_id', v_settle))->>'account_id')::int INTO v_depot;

  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin','IE00BK5BQT80','symbol','VWCE','name','Vanguard FTSE All-World','shares',10,'price_per_share',100,
    'order_fee',0,'transaction_date',CURRENT_DATE::text,'existing_position',true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL takeover [1]: ok=true erwartet, got %', v_res;
  END IF;
  -- Post-State: Saldo bleibt 2500, Stueck 10, Einstand 100
  IF (v_res->>'settlement_balance')::numeric IS DISTINCT FROM 2500.00
     OR (v_res->>'total_shares')::numeric IS DISTINCT FROM 10
     OR (v_res->>'avg_purchase_price')::numeric IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL takeover [1]: Saldo 2500 / 10 Stueck / Einstand 100 erwartet, got %', v_res;
  END IF;
  v_buy  := (v_res->>'buy_tx_id')::int;
  v_hold := (v_res->>'holding_id')::int;
  SELECT group_id INTO v_group FROM finance.transactions WHERE id = v_buy;
  IF v_group IS NULL OR (SELECT count(*) FROM finance.transactions
        WHERE group_id = v_group AND category = 'position_takeover' AND amount = 1000 AND account_id = v_settle
          AND holding_id IS NULL) <> 1 THEN
    RAISE EXCEPTION 'FAIL takeover [1]: Kauf + genau eine Gegenbuchung +1000 in derselben group_id erwartet';
  END IF;
  RAISE NOTICE 'PASS takeover [1 Saldo unveraendert 2500, 10 Stueck, Einstand 100, Gegenbuchung in group_id]';

  -- TEST 2: erneute Uebernahme derselben Position -> ok:false (sonst Verdopplung), kein Write
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin','IE00BK5BQT80','symbol','VWCE','shares',12,'price_per_share',100,
    'transaction_date',CURRENT_DATE::text,'existing_position',true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'held_shares')::numeric IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'FAIL takeover [2]: Doppel-Uebernahme muss ok=false (held_shares 10) liefern, got %', v_res;
  END IF;
  IF (SELECT shares FROM finance.depot_holdings WHERE id = v_hold) <> 10 THEN
    RAISE EXCEPTION 'FAIL takeover [2]: Bestand veraendert trotz ok=false';
  END IF;
  RAISE NOTICE 'PASS takeover [2 Doppel-Uebernahme -> ok:false, Bestand bleibt 10]';

  -- TEST 3: Bestandsuebernahme als Sparplan-Ausfuehrung -> ok:false
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin','IE00B4L5Y983','symbol','IWDA','shares',1,'price_per_share',80,'transaction_date',CURRENT_DATE::text,
    'existing_position',true,'recurring_payment_id',999999)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL takeover [3]: existing_position + recurring_payment_id muss ok=false liefern, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS takeover [3 mit Sparplan-Bezug -> ok:false]';

  -- TEST 4: normaler Kauf bleibt unveraendert (Geld fliesst ab, keine Gegenbuchung, keine group_id)
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin','IE00BK5BQT80','symbol','VWCE','shares',2,'price_per_share',110,'order_fee',1,
    'transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'settlement_balance')::numeric IS DISTINCT FROM 2279.00
     OR (SELECT group_id FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL takeover [4]: normaler Kauf muss 221 abbuchen (2279) ohne group_id, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS takeover [4 normaler Nachkauf bucht ab, ohne group_id]';

  -- TEST 5: CHECK-Backstop der Gegenbuchungs-Form (negativ / ohne group_id)
  v_ok := false;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_settle, 50, CURRENT_DATE, 'position_takeover');
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL takeover [5]: position_takeover ohne group_id haette der CHECK ablehnen muessen'; END IF;
  RAISE NOTICE 'PASS takeover [5 CHECK finance_transactions_position_takeover_shape greift]';

  -- TEST 6: Void der Uebernahme entfernt Kauf UND Gegenbuchung (eine group_id = ein Void)
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_buy)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE group_id = v_group) THEN
    RAISE EXCEPTION 'FAIL takeover [6]: Void muss beide Zeilen der Gruppe entfernen, got %', v_res;
  END IF;
  SELECT balance INTO v_bal FROM finance.account_balances WHERE account_id = v_settle;
  IF v_bal IS DISTINCT FROM 2279.00 THEN
    RAISE EXCEPTION 'FAIL takeover [6]: Saldo nach Void erwartet 2279 (nur der echte Nachkauf bleibt), got %', v_bal;
  END IF;
  RAISE NOTICE 'PASS takeover [6 Void entfernt Kauf + Gegenbuchung, Saldo 2279]';

  -- TEST 7: Krypto-Uebernahme OHNE name (Owner-Import 2026-10-22: "Bezeichnung: —") -> ok, Name = Symbol.
  -- Vorher schrieb die fn NULL in depot_holdings.name (NOT NULL) -> RAISE -> ganzer Import zurueckgerollt.
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_take_crypto__','account_type','crypto_depot',
    'settlement_id', v_settle))->>'account_id')::int INTO v_depot;
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
    'isin','','symbol','ETH','shares',0.71925384,'price_per_share',1846.30,
    'transaction_date',CURRENT_DATE::text,'existing_position',true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'total_shares')::numeric IS DISTINCT FROM 0.71925384 THEN
    RAISE EXCEPTION 'FAIL takeover [7]: Uebernahme ohne name muss ok=true mit 0.71925384 Stueck liefern, got %', v_res;
  END IF;
  IF (SELECT name FROM finance.depot_holdings WHERE id = (v_res->>'holding_id')::int) IS DISTINCT FROM 'ETH' THEN
    RAISE EXCEPTION 'FAIL takeover [7]: ohne name muss die Position das Symbol ETH als Namen tragen';
  END IF;
  RAISE NOTICE 'PASS takeover [7 ohne name -> Name = Symbol, 8 Nachkommastellen erhalten]';
END $$;

-- ============================================================
-- Live-Befund 2026-10-28: settlement_change (DB-Delta statt vom Modell hergeleitet), Uebernahme mit Gesamtbetrag
-- (cost_basis_total, Stueckpreis rechnet die DB) und eine Doppel-Uebernahme-Meldung ohne "normaler Kauf"-Empfehlung.
-- ============================================================
DO $$
DECLARE
  v_res JSONB; v_settle INT; v_depot INT;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__test_take2_settle__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__test_take2_depot__','account_type','stocks_depot',
               'settlement_id', v_settle))->>'account_id')::int;

  -- TEST 8: Uebernahme mit Gesamtbetrag 1.000 fuer 75.12345 Stueck -> Stueckpreis = round(1000/75.12345, 8), Saldo unveraendert
  v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3XXRP09',
           'symbol','VUSA','shares',75.12345,'cost_basis_total',1000,'existing_position',true));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->>'avg_purchase_price')::numeric IS DISTINCT FROM round(1000 / 75.12345, 8)
     OR (v_res->>'settlement_balance')::numeric IS DISTINCT FROM 5000
     OR (v_res->>'settlement_change')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL takeover [8 cost_basis_total]: %', v_res; END IF;
  RAISE NOTICE 'PASS takeover [8 Gesamtbetrag -> Stueckpreis aus der DB, settlement_change 0]';
  IF (v_res->'effective'->>'price_per_share')::numeric IS DISTINCT FROM round(1000 / 75.12345, 8) THEN
    RAISE EXCEPTION 'FAIL takeover [8b effective]: Probelauf muss den Stueckpreis fuer Karte + Write liefern, got %', v_res; END IF;
  -- Gate-Write = Start-Felder || effective -> beide Felder, gleicher Wert = ok (Probelauf zurueckgerollt simuliert)
  v_res := core.fn_dry_run('finance.fn_book_stock_buy(jsonb)'::regprocedure, jsonb_build_object('depot_id',v_depot,
           'settlement_id',v_settle,'isin','IE00B3XXRP10','symbol','VUSB','shares',3,'cost_basis_total',100,
           'price_per_share',round(100 / 3.0, 8),'existing_position',true));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL takeover [8c Write mit effective]: %', v_res; END IF;
  RAISE NOTICE 'PASS takeover [8b/8c Stueckpreis in effective, Write mit beiden Feldern ok]';

  -- TEST 9: Doppel-Uebernahme -> ok:false, Meldung empfiehlt set_holding, nie einen normalen Kauf
  v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3XXRP09',
           'symbol','VUSA','shares',1,'price_per_share',13,'existing_position',true));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'held_shares')::numeric IS DISTINCT FROM 75.12345
     OR v_res->>'reason' NOT LIKE '%set_holding%' OR v_res->>'reason' ILIKE '%normal buy%' THEN
    RAISE EXCEPTION 'FAIL takeover [9 Meldung]: %', v_res; END IF;
  RAISE NOTICE 'PASS takeover [9 Doppel-Uebernahme -> set_holding, kein normaler Kauf empfohlen]';

  -- TEST 10: normaler Kauf -> settlement_change = -(Stueck*Kurs+Gebuehr)
  v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3XXRP09',
           'symbol','VUSA','shares',2,'price_per_share',14.5,'order_fee',1));
  IF (v_res->>'settlement_change')::numeric IS DISTINCT FROM -30 OR (v_res->>'settlement_balance')::numeric IS DISTINCT FROM 4970 THEN
    RAISE EXCEPTION 'FAIL buy [10 settlement_change]: %', v_res; END IF;
  RAISE NOTICE 'PASS buy [10 normaler Kauf: settlement_change -30]';

  -- TEST 11: cost_basis_total ohne existing_position bzw. zusammen mit price_per_share -> ok:false
  v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3XXRP09',
           'symbol','VUSA','shares',2,'cost_basis_total',30));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL buy [11 cost_basis_total ohne Uebernahme]: %', v_res; END IF;
  RAISE NOTICE 'PASS buy [11 cost_basis_total nur fuer Uebernahme]';
  -- TEST 12: freie Tool-Eingaben als Text: Gesamtbetrag "1.234,50" + leerer Kurs -> geparst; unlesbar -> ok:false (kein RAISE)
  v_res := core.fn_dry_run('finance.fn_book_stock_buy(jsonb)'::regprocedure, jsonb_build_object('depot_id',v_depot,
           'settlement_id',v_settle,'isin','IE00B3XXRP11','symbol','VUSC','shares','10','price_per_share',0,
           'cost_basis_total','1.234,50','existing_position',true));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'avg_purchase_price')::numeric IS DISTINCT FROM 123.45 THEN
    RAISE EXCEPTION 'FAIL takeover [12a Text-Gesamtbetrag]: %', v_res; END IF;
  v_res := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3XXRP12',
           'symbol','VUSD','shares',10,'cost_basis_total','etwa tausend','existing_position',true));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%cost_basis_total%' THEN
    RAISE EXCEPTION 'FAIL takeover [12b unlesbar]: %', v_res; END IF;
  RAISE NOTICE 'PASS takeover [12 Text-Eingaben geparst, unlesbarer Gesamtbetrag -> ok:false]';
END $$;

ROLLBACK;
