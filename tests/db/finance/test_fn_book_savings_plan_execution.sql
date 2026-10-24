-- tests/db/finance/test_fn_book_savings_plan_execution.sql
-- Testet fn_book_savings_plan_execution: Bruchteil-Kauf, rp_id auf Tx, Holding-Trigger,
--   Vorkommen geschlossen, Plan-Status-Guard, kein offenes Vorkommen, Crypto-Pfad
BEGIN;

DO $$
DECLARE
  v_result         JSONB;
  v_settle_id      INT;
  v_depot_id       INT;
  v_crypto_id      INT;
  v_plan_id        INT;
  v_rp_id          INT;
  v_holding_id     INT;
  v_buy_tx_id      INT;
  v_tx_rp_id       INT;
  v_tx_date        DATE;
  v_holding_shares NUMERIC;
  v_due_date       DATE;
  v_past_date      DATE;
BEGIN

  v_past_date := CURRENT_DATE - 5;

  -- Setup: Verrechnungskonto
  SELECT finance.fn_create_account(
    '{"name":"__test_bse_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  -- Setup: Aktiendepot
  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_bse_depot__',
    'account_type', 'stocks_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Setup: Crypto-Depot
  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_bse_crypto__',
    'account_type', 'crypto_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_crypto_id := (v_result->>'account_id')::int;

  -- Setup: ETF-Sparplan mit first_payment_date in der Vergangenheit (dom=NULL -> Vorkommen am
  --   first_payment_date selbst) -> genau ein offenes Vorkommen fuer fn_recurring_due_open
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_bse_plan_etf__',
    'depot_name',        '__test_bse_depot__',
    'isin',              'IE00B3RBWM25',
    'symbol',            'VWCE',
    'security_name',     'Vanguard FTSE All-World',
    'amount',            100,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', v_past_date
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan [ETF]: %', v_result->>'reason';
  END IF;
  v_plan_id := (v_result->>'savings_plan_id')::int;
  v_rp_id   := (v_result->>'recurring_payment_id')::int;

  -- TEST 1: Bruchteil-Kauf 0.8234 VWCE @ 121.50 + 1.00 Gebühr (Abweichung ~1% < 5%)
  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
    'savings_plan_name', '__test_bse_plan_etf__',
    'shares',            0.8234,
    'price_per_share',   121.50,
    'order_fee',         1.00
  )) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [Bruchteil-Kauf]: ok=false, reason=%',
      v_result->>'reason';
  END IF;
  v_holding_id := (v_result->>'holding_id')::int;
  v_buy_tx_id  := (v_result->>'buy_tx_id')::int;
  v_due_date   := (v_result->>'due_date')::date;
  IF v_holding_id IS NULL OR v_buy_tx_id IS NULL OR v_due_date IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [IDs/due_date fehlen]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [Bruchteil-Kauf ok]: holding=%, tx=%, due=%',
    v_holding_id, v_buy_tx_id, v_due_date;

  -- Assert: Transaktion trägt recurring_payment_id + transaction_date == due_date
  SELECT t.recurring_payment_id, t.transaction_date
  INTO v_tx_rp_id, v_tx_date
  FROM finance.transactions t WHERE t.id = v_buy_tx_id;

  IF v_tx_rp_id IS DISTINCT FROM v_rp_id THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [rp_id auf Tx]: erwartet %, got %',
      v_rp_id, v_tx_rp_id;
  END IF;
  IF v_tx_date IS DISTINCT FROM v_due_date THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [tx_date=due_date]: erwartet %, got %',
      v_due_date, v_tx_date;
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [rp_id auf Tx: %, date: %]',
    v_tx_rp_id, v_tx_date;

  -- Assert: Holding-Shares korrekt (DB-Trigger)
  SELECT shares INTO v_holding_shares
  FROM finance.depot_holdings WHERE id = v_holding_id;
  IF v_holding_shares IS DISTINCT FROM 0.8234 THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [Holding-Shares]: erwartet 0.8234, got %',
      v_holding_shares;
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [Holding-Shares via Trigger: %]',
    v_holding_shares;

  -- Assert: Vorkommen nicht mehr in fn_recurring_due_open (rp_id + due_date gebucht)
  IF EXISTS (
    SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE)
    WHERE recurring_payment_id = v_rp_id AND due_date = v_due_date
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [Vorkommen still open nach Buchung]';
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [Vorkommen geschlossen nach Buchung]';

  -- TEST 2: Paused Plan -> {ok:false}
  UPDATE finance.savings_plans SET status = 'paused' WHERE id = v_plan_id;

  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
    'savings_plan_name', '__test_bse_plan_etf__',
    'shares',            1.0,
    'price_per_share',   100.0
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [paused Plan]: erwartet ok=false, got %',
      v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [paused Plan -> ok:false]';

  -- Plan wieder aktivieren
  UPDATE finance.savings_plans SET status = 'active' WHERE id = v_plan_id;

  -- TEST 3: Kein offenes Vorkommen (future first_payment_date) -> {ok:false}
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_bse_plan_future__',
    'depot_name',        '__test_bse_depot__',
    'isin',              'IE00B4L5Y983',
    'symbol',            'IWDA',
    'security_name',     'iShares Core MSCI World',
    'amount',            50,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', (CURRENT_DATE + INTERVAL '30 days')::date
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan [future plan]: %', v_result->>'reason';
  END IF;

  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
    'savings_plan_name', '__test_bse_plan_future__',
    'shares',            1.0,
    'price_per_share',   50.0
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [kein Vorkommen]: erwartet ok=false, got %',
      v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [kein offenes Vorkommen -> ok:false]';

  -- TEST 4: Crypto-Plan ohne ISIN (BTC, Bruchteile < 1)
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_bse_plan_btc__',
    'depot_name',        '__test_bse_crypto__',
    'symbol',            'BTC',
    'security_name',     'Bitcoin',
    'amount',            25,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', CURRENT_DATE - 3
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan [BTC plan]: %', v_result->>'reason';
  END IF;

  SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
    'savings_plan_name', '__test_bse_plan_btc__',
    'shares',            0.00024000,
    'price_per_share',   104166.67
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_book_savings_plan_execution [Crypto]: ok=false, reason=%',
      v_result->>'reason';
  END IF;
  RAISE NOTICE 'PASS fn_book_savings_plan_execution [Crypto BTC ohne ISIN -> ok:true]';

  -- TEST 5 (Phase L WS-6): asset_class-Vererbung Sparplan -> Ausfuehrung -> Holding.
  DECLARE
    v_cls TEXT; v_hold5 INT; v_hold_m1 INT;
  BEGIN
    -- (5a) Plan MIT asset_class auf NEUER Position -> Ausfuehrung legt die Holding getaggt an.
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_bse_plan_tagged__','depot_name','__test_bse_depot__',
      'isin','IE00TAG00001','symbol','TAGG','security_name','Tagged ETF',
      'amount',100,'schedule_interval',1,'schedule_unit','month','first_payment_date', v_past_date,
      'asset_class','sp500')) INTO v_result;
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE EXCEPTION 'SETUP FAIL [5a plan]: %', v_result->>'reason'; END IF;
    SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
      'savings_plan_name','__test_bse_plan_tagged__','shares',0.5,'price_per_share',200.0)) INTO v_result;
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE EXCEPTION 'FAIL [5a exec]: %', v_result->>'reason'; END IF;
    v_hold5 := (v_result->>'holding_id')::int;
    SELECT asset_class INTO v_cls FROM finance.depot_holdings WHERE id = v_hold5;
    IF v_cls IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL [5a]: Sparplan-Ausfuehrung vererbt asset_class nicht, erwartet sp500, got %', v_cls; END IF;
    RAISE NOTICE 'PASS [5a WS-6: Sparplan mit asset_class -> Ausfuehrung legt Holding getaggt an]';

    -- (5b, m1) Eine zuerst MANUELL untagged angelegte Position bleibt untagged, auch wenn spaeter ein getaggter
    --   Sparplan einzahlt (fn_book_stock_buy taggt nur beim ANLEGEN -> Re-Buy ist no-op, kein Ueberschreiben).
    SELECT finance.fn_book_stock_buy(jsonb_build_object(
      'depot_id', v_depot_id, 'settlement_id', v_settle_id,
      'isin','IE00M1000001','symbol','M1ID','name','M1 ETF',
      'shares',1,'price_per_share',100,'order_fee',0,'transaction_date', CURRENT_DATE::text)) INTO v_result;   -- KEIN asset_class -> untagged
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE EXCEPTION 'SETUP FAIL [5b manual buy]: %', v_result->>'reason'; END IF;
    v_hold_m1 := (v_result->>'holding_id')::int;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_bse_plan_m1__','depot_name','__test_bse_depot__',
      'isin','IE00M1000001','symbol','M1ID','security_name','M1 ETF',
      'amount',100,'schedule_interval',1,'schedule_unit','month','first_payment_date', v_past_date,
      'asset_class','gold')) INTO v_result;
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE EXCEPTION 'SETUP FAIL [5b plan]: %', v_result->>'reason'; END IF;
    SELECT finance.fn_book_savings_plan_execution(jsonb_build_object(
      'savings_plan_name','__test_bse_plan_m1__','shares',1,'price_per_share',100.0)) INTO v_result;
    IF NOT (v_result->>'ok')::boolean THEN
      RAISE EXCEPTION 'FAIL [5b exec]: %', v_result->>'reason'; END IF;
    SELECT asset_class INTO v_cls FROM finance.depot_holdings WHERE id = v_hold_m1;
    IF v_cls IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [5b m1]: getaggter Sparplan ueberschrieb die untagged Position, erwartet NULL, got %', v_cls; END IF;
    RAISE NOTICE 'PASS [5b WS-6/m1: getaggter Sparplan-Kauf in untagged Bestand -> kein Ueberschreiben]';
  END;

END $$;

ROLLBACK;
