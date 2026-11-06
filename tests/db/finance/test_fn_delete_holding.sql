-- tests/db/finance/test_fn_delete_holding.sql
-- Testet fn_delete_holding: Hard-DELETE (leere Position), Guard (Trades vorhanden), not-found
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_settle  INT; v_depot INT;
  v_h_a     INT; v_h_b INT;
  v_cnt     INT;
BEGIN
  -- Setup: Verrechnungskonto + Aktiendepot
  SELECT finance.fn_create_account('{"name":"__test_dh_settle__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_settle := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_dh_depot__','account_type','stocks_depot',
    'account_holder','Test','settlement_id',v_settle)) INTO v_res;
  v_depot := (v_res->>'account_id')::int;

  -- Holding A: keine Buchungen -> loeschbar
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00BK5BQT80', 'VWCE', 'Vanguard') RETURNING id INTO v_h_a;

  -- Holding B: mit einem Trade -> Guard
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00B4L5Y983', 'IWDA', 'iShares') RETURNING id INTO v_h_b;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description)
  VALUES (v_settle, -1101, CURRENT_DATE, 'buy', v_h_b, 10, 1, 'Kauf IWDA');

  -- TEST 1: Hard-DELETE
  SELECT finance.fn_delete_holding(jsonb_build_object('holding_id', v_h_a)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL delete_holding [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.depot_holdings WHERE id = v_h_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_holding [holding A noch da]'; END IF;
  RAISE NOTICE 'PASS delete_holding [Hard-DELETE leere Position]';

  -- TEST 2: Guard (Trades vorhanden) -> {ok:false}, nichts geloescht
  SELECT finance.fn_delete_holding(jsonb_build_object('holding_id', v_h_b)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'transaction_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL delete_holding [trade-guard]: erwartet ok=false transaction_count=1, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.depot_holdings WHERE id = v_h_b;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_holding [holding B faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_holding [trade-guard: ok=false, Position bleibt]';

  -- TEST 3: not-found -> RAISE
  BEGIN
    SELECT finance.fn_delete_holding(jsonb_build_object('holding_id', 99999999)) INTO v_res;
    RAISE EXCEPTION 'FAIL delete_holding [not-found]: haette RAISE werfen muessen';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' THEN RAISE NOTICE 'PASS delete_holding [not-found]';
    ELSE RAISE EXCEPTION 'FAIL delete_holding [not-found]: falscher Fehler: %', SQLERRM; END IF;
  END;
END $$;

ROLLBACK;
