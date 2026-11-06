-- tests/db/finance/test_fn_book_stock_sell.sql
-- Testet fn_book_stock_sell: Shares-Reduktion, Settlement-Kredit, avg unveraendert, Guard
BEGIN;

DO $$
DECLARE
  v_result     JSONB;
  v_settle_id  INT;
  v_depot_id   INT;
  v_holding_id INT;
  v_sell_tx_id INT;
  v_buy_shares NUMERIC := 10;
  v_buy_price  NUMERIC := 80;
  v_buy_fee    NUMERIC := 5;
  v_sell_shares NUMERIC := 4;
  v_sell_price  NUMERIC := 90;
  v_sell_fee    NUMERIC := 3;
  v_exp_avg     NUMERIC;
  v_got_shares  NUMERIC;
  v_got_avg     NUMERIC;
  v_got_bal     NUMERIC;
BEGIN

  -- Setup: Settlement-Konto + Depot
  SELECT finance.fn_create_account(
    '{"name":"__test_sell_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(jsonb_build_object(
    'name',           '__test_sell_depot__',
    'account_type',   'stocks_depot',
    'account_holder', 'Test',
    'currency',       'EUR',
    'settlement_id',  v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Kauf: 10 Anteile @ 80 + 5 Gebuehr -> avg = 80.5
  SELECT finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id',        v_depot_id,
    'settlement_id',   v_settle_id,
    'isin',            'IE00B4L5Y983',
    'symbol',          'IUSQ',
    'name',            'iShares MSCI World',
    'shares',          v_buy_shares,
    'price_per_share', v_buy_price,
    'order_fee',       v_buy_fee,
    'transaction_date', CURRENT_DATE::text
  )) INTO v_result;
  v_holding_id := (v_result->>'holding_id')::int;
  v_exp_avg := (v_buy_shares * v_buy_price + v_buy_fee) / v_buy_shares;  -- 80.5

  -- TEST 1: Verkauf 4 Anteile @ 90 - 3 Gebuehr
  SELECT finance.fn_book_stock_sell(jsonb_build_object(
    'settlement_id',   v_settle_id,
    'holding_id',      v_holding_id,
    'shares',          v_sell_shares,
    'price_per_share', v_sell_price,
    'order_fee',       v_sell_fee,
    'transaction_date', CURRENT_DATE::text,
    'symbol',          'IUSQ'
  )) INTO v_result;

  IF NOT (v_result ? 'sell_tx_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell: kein sell_tx_id im Result, got %', v_result;
  END IF;
  v_sell_tx_id := (v_result->>'sell_tx_id')::int;

  -- Assert: shares = 10 - 4 = 6
  SELECT shares, average_purchase_price INTO v_got_shares, v_got_avg
  FROM finance.depot_holdings WHERE id = v_holding_id;

  IF v_got_shares IS DISTINCT FROM (v_buy_shares - v_sell_shares) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [shares]: erwartet %, got %',
      v_buy_shares - v_sell_shares, v_got_shares;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [shares]: %', v_got_shares;

  -- Assert: avg_price unveraendert (Sell-Trigger liest nur buy)
  IF round(v_got_avg, 4) IS DISTINCT FROM round(v_exp_avg, 4) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [avg unveraendert]: erwartet %, got %',
      v_exp_avg, v_got_avg;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [avg unveraendert]: %', v_got_avg;

  -- Assert: Settlement-Balance = -805 (buy) + (4*90-3) = -805 + 357 = -448
  SELECT finance.fn_get_balance(v_settle_id) INTO v_got_bal;
  IF v_got_bal IS DISTINCT FROM (-(v_buy_shares*v_buy_price + v_buy_fee) + (v_sell_shares*v_sell_price - v_sell_fee)) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [settle_bal]: erwartet %, got %',
      -(v_buy_shares*v_buy_price + v_buy_fee) + (v_sell_shares*v_sell_price - v_sell_fee), v_got_bal;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [settle_bal]: %', v_got_bal;

  -- Assert: category='sell', shares negativ, order_fee gespeichert
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_sell_tx_id AND category = 'sell' AND shares = -v_sell_shares AND order_fee = v_sell_fee
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell: category/shares/order_fee in TX falsch';
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [tx_fields korrekt]';

  -- Assert: Post-State-Vertrag — settlement_balance/proceeds/remaining_shares im Return
  IF (v_result->>'settlement_balance')::numeric IS DISTINCT FROM v_got_bal THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [return settlement_balance]: erwartet %, got %', v_got_bal, v_result->>'settlement_balance';
  END IF;
  IF (v_result->>'proceeds')::numeric IS DISTINCT FROM (v_sell_shares*v_sell_price - v_sell_fee) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [return proceeds]: erwartet %, got %', (v_sell_shares*v_sell_price - v_sell_fee), v_result->>'proceeds';
  END IF;
  IF (v_result->>'remaining_shares')::numeric IS DISTINCT FROM (v_buy_shares - v_sell_shares) THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [return remaining_shares]: erwartet %, got %', (v_buy_shares - v_sell_shares), v_result->>'remaining_shares';
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [Post-State Return korrekt]';

  -- TEST 2: Oversell -> {ok:false} (korrigierbar, kein RAISE) + available/requested
  SELECT finance.fn_book_stock_sell(jsonb_build_object(
    'settlement_id',   v_settle_id,
    'holding_id',      v_holding_id,
    'shares',          100,
    'price_per_share', 90,
    'order_fee',       0,
    'transaction_date', CURRENT_DATE::text,
    'symbol',          'IUSQ'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [oversell]: erwartet ok=false, got %', v_result;
  END IF;
  IF (v_result->>'available')::numeric IS DISTINCT FROM (v_buy_shares - v_sell_shares)
     OR (v_result->>'requested')::numeric IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [oversell fields]: available/requested falsch, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [oversell -> ok:false]: %', v_result->>'reason';

  -- TEST 3: shares <= 0 -> {ok:false}
  SELECT finance.fn_book_stock_sell(jsonb_build_object(
    'settlement_id', v_settle_id, 'holding_id', v_holding_id,
    'shares', 0, 'price_per_share', 90, 'order_fee', 0,
    'transaction_date', CURRENT_DATE::text, 'symbol', 'IUSQ'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [shares<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [shares<=0 -> ok:false]';

  -- TEST 4: price <= 0 -> {ok:false}
  SELECT finance.fn_book_stock_sell(jsonb_build_object(
    'settlement_id', v_settle_id, 'holding_id', v_holding_id,
    'shares', 2, 'price_per_share', 0, 'order_fee', 0,
    'transaction_date', CURRENT_DATE::text, 'symbol', 'IUSQ'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_stock_sell [price<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_stock_sell [price<=0 -> ok:false]';

END $$;

-- TEST 5-7 (Audit F3): gleitender Durchschnitt (Durchschnittskostenmethode) bei Nachkauf nach Verkauf.
--   Vorher summierte der Trigger ALLE Kaeufe aller Zeiten (2000/15 = 133.33 statt 150).
DO $$
DECLARE
  v_result  JSONB;
  v_settle  INT;
  v_depot   INT;
  v_h       INT;
  v_avg     NUMERIC;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_avg_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_avg_depot__','account_type','stocks_depot',
    'account_holder','Test','currency','EUR','settlement_id',v_settle)) INTO v_result;
  v_depot := (v_result->>'account_id')::int;

  -- TEST 5: 10 @ 100, Verkauf 5, Nachkauf 5 @ 200 -> (5*100 + 5*200) / 10 = 150
  v_result := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B4L5Y983','symbol','AVGA','name','A','shares',10,'price_per_share',100,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  v_h := (v_result->>'holding_id')::int;
  PERFORM finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'shares',5,
    'price_per_share',150,'order_fee',0,'transaction_date',CURRENT_DATE::text,'symbol','AVGA'));
  v_result := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B4L5Y983','symbol','AVGA','name','A','shares',5,'price_per_share',200,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  IF (v_result->>'avg_purchase_price')::numeric IS DISTINCT FROM 150 THEN
    RAISE EXCEPTION 'FAIL avg [Teilverkauf+Nachkauf]: erwartet 150, got %', v_result->>'avg_purchase_price';
  END IF;
  RAISE NOTICE 'PASS avg [Teilverkauf+Nachkauf -> 150]';

  -- TEST 6: 10 @ 100, Vollverkauf, Nachkauf 10 @ 200 -> neue Position startet neu = 200
  v_result := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B3RBWM25','symbol','AVGB','name','B','shares',10,'price_per_share',100,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  v_h := (v_result->>'holding_id')::int;
  PERFORM finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'shares',10,
    'price_per_share',150,'order_fee',0,'transaction_date',CURRENT_DATE::text,'symbol','AVGB'));
  SELECT average_purchase_price INTO v_avg FROM finance.depot_holdings WHERE id = v_h;
  IF v_avg IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL avg [Vollverkauf: letzter Durchschnitt sichtbar]: erwartet 100, got %', v_avg;
  END IF;
  v_result := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B3RBWM25','symbol','AVGB','name','B','shares',10,'price_per_share',200,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  IF (v_result->>'avg_purchase_price')::numeric IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL avg [Vollverkauf+Nachkauf]: erwartet 200, got %', v_result->>'avg_purchase_price';
  END IF;
  RAISE NOTICE 'PASS avg [Vollverkauf+Nachkauf -> 200]';

  -- TEST 7: rueckdatierter Verkauf VOR dem Kauf (Bestand chronologisch negativ) -> kein Division-durch-0,
  --   der Kauf startet die Kostenbasis neu: avg = 100
  v_result := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','DE0005190003','symbol','AVGC','name','C','shares',10,'price_per_share',100,'order_fee',0,
    'transaction_date',CURRENT_DATE::text));
  v_h := (v_result->>'holding_id')::int;
  PERFORM finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'shares',5,
    'price_per_share',150,'order_fee',0,'transaction_date',(CURRENT_DATE - 1)::text,'symbol','AVGC'));
  SELECT average_purchase_price INTO v_avg FROM finance.depot_holdings WHERE id = v_h;
  IF v_avg IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL avg [Verkauf vor Kauf]: erwartet 100, got %', v_avg;
  END IF;
  RAISE NOTICE 'PASS avg [rueckdatierter Verkauf vor Kauf -> 100, kein Fehler]';
END $$;

-- Verkauf mit Sparziel (Umschichten Depot -> Konto, Sparziel-Zweckbindung 2026-10-27):
--  (G1) Ziel hat 1000 EUR im Depot zugeordnet; Verkauf mit Erloes 600 und savings_goal_name -> derisk: Depot -600,
--       Verrechnungskonto +600 (source_tx_id = Verkauf), Fortschritt unveraendert 1000, derisk_amount 600
--  (G2) zweiter Verkauf mit Erloes 800 -> nur der Rest 400 wird umgeschichtet (m = min(Anteil, Erloes))
--  (G3) Ziel ohne Geld in diesem Depot -> ok:false, kein Verkauf
--  (G4) unbekanntes Ziel -> ok:false
--  (G5) Verrechnungskonto in anderer Waehrung als das Depot -> ok:false (wie beim Kauf)
DO $$
DECLARE v_settle int; v_depot int; v_hold int; v_goal int; v_goal2 int; v_r jsonb; v_cur numeric; v_cnt int; v_sell int;
        v_usd_depot int; v_usd_hold int;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__sg_sell_settle__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__sg_sell_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  v_r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983','symbol','IUSQ',
           'name','iShares MSCI World','shares',20,'price_per_share',100,'order_fee',0,'transaction_date',(CURRENT_DATE - 10)::text));
  v_hold := (v_r->>'holding_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sg_sell Auto__', 5000, current_date + 400, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__sg_sell Leer__', 5000, current_date + 400, 'active') RETURNING id INTO v_goal2;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 1000));

  -- (G1)
  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_hold,'shares',5,'price_per_share',120,
           'order_fee',0,'symbol','IUSQ','savings_goal_name','__sg_sell Auto__'));
  v_sell := (v_r->>'sell_tx_id')::int;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'derisk_amount')::numeric IS DISTINCT FROM 600 OR v_cur IS DISTINCT FROM 1000
     OR (SELECT delta_native FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_sell AND account_id = v_depot AND kind = 'derisk') IS DISTINCT FROM -600
     OR (SELECT delta_native FROM finance.savings_goal_reserve_entries WHERE source_tx_id = v_sell AND account_id = v_settle AND kind = 'derisk') IS DISTINCT FROM 600 THEN
    RAISE EXCEPTION 'FAIL sell [G1 derisk]: % / current %', v_r, v_cur; END IF;
  RAISE NOTICE 'PASS sell [G1: Erloes 600 vom Depot aufs Konto umgeschichtet, Ziel 1000]';

  -- (G2)
  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_hold,'shares',8,'price_per_share',100,
           'order_fee',0,'symbol','IUSQ','savings_goal_name','__sg_sell Auto__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'derisk_amount')::numeric IS DISTINCT FROM 400
     OR (SELECT share_eur FROM finance.savings_goal_account_share WHERE goal_id = v_goal AND account_id = v_depot) IS DISTINCT FROM 0
     OR (SELECT current_amount FROM finance.savings_goal_progress WHERE id = v_goal) IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL sell [G2 Rest]: %', v_r; END IF;
  RAISE NOTICE 'PASS sell [G2: nur der Rest 400 umgeschichtet, Depot-Anteil 0]';

  -- (G3)
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE holding_id = v_hold AND category = 'sell';
  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_hold,'shares',1,'price_per_share',100,
           'order_fee',0,'symbol','IUSQ','savings_goal_name','__sg_sell Leer__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_hold AND category = 'sell') <> v_cnt THEN
    RAISE EXCEPTION 'FAIL sell [G3 kein Ziel-Geld im Depot]: %', v_r; END IF;
  -- (G4)
  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_hold,'shares',1,'price_per_share',100,
           'order_fee',0,'symbol','IUSQ','savings_goal_name','__sg_sell Gibtsnicht__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL sell [G4 unbekanntes Ziel]: %', v_r; END IF;
  -- (G5)
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__sg_sell_usd_depot__','stocks_depot','USD','active', v_settle) RETURNING id INTO v_usd_depot;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_usd_depot, 'USDX', 'USD Test', 10, 10, 'USD') RETURNING id INTO v_usd_hold;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind) VALUES (v_goal2, v_usd_depot, 50, 'EUR', 'manual');
  v_r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_usd_hold,'shares',1,'price_per_share',10,
           'order_fee',0,'symbol','USDX','savings_goal_name','__sg_sell Leer__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT ILIKE '%currency%' THEN
    RAISE EXCEPTION 'FAIL sell [G5 Waehrung]: %', v_r; END IF;
  RAISE NOTICE 'PASS sell [G3 kein Ziel-Geld, G4 unbekanntes Ziel, G5 Waehrung -> ok:false ohne Verkauf]';
END $$;

ROLLBACK;
