-- tests/db/finance/test_rounding.sql
-- Rundungs-Paket 2026-10-23 (Owner-Fund: eine Bestandsuebernahme zeigte den Einstand nachgerechnet statt genannt, z. B. 54217.93 statt 54218).
--   [R1] Bestandsuebernahme speichert den genannten Stueckpreis (unit_price) -> Einstand exakt; normaler Kauf bleibt
--        Broker-Konvention (Cent-Betrag inkl. Gebuehr / Stueck).
--   [R2] Mini-Kauf / Verkauf mit Gebuehr >= Erloes / > 8 Stueck-Nachkommastellen -> {ok:false} statt CHECK-RAISE.
--   [R3] CHECK finance_transactions_unit_price_chk (V019): unit_price muss zum gebuchten Betrag passen.
--   [R4] V019-Backfill (Logik-KOPIE der Migration, Muster test_core_contexts_provenance): Preis aus der eigenen
--        Buchungsbeschreibung, nur bei exakter Uebereinstimmung mit dem Betrag; "Gebuehr"/"Gebühr", leere Gebuehr.
--   [R5] fn_to_eur_unrounded: ungerundete Kurs-Umrechnung; fn_to_eur unveraendert (EUR ungerundet, sonst Cent).
BEGIN;

DO $$
DECLARE
  v_cash  INT;
  v_depot INT;
  v_res   JSONB;
  v_hold  INT;
  v_ok    BOOLEAN;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__rnd cash__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int INTO v_cash;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__rnd crypto__','account_type','crypto_depot',
    'settlement_id', v_cash))->>'account_id')::int INTO v_depot;

  -- [R1a] Uebernahme 0.06127493 BTC @ 54218 -> Einstand exakt 54218, unit_price gespeichert
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','BTC',
    'shares', 0.06127493, 'price_per_share', 54218, 'transaction_date', CURRENT_DATE::text, 'existing_position', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'avg_purchase_price')::numeric IS DISTINCT FROM 54218 THEN
    RAISE EXCEPTION 'FAIL [R1a]: Uebernahme muss Einstand 54218 liefern, got %', v_res;
  END IF;
  IF (SELECT unit_price FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int) IS DISTINCT FROM 54218 THEN
    RAISE EXCEPTION 'FAIL [R1a]: unit_price 54218 erwartet';
  END IF;
  RAISE NOTICE 'PASS [R1a Uebernahme -> Einstand 54218 exakt]';

  -- [R1b] normaler Kauf: Einstand = Cent-Betrag inkl. Gebuehr / Stueck (Broker-Konvention), kein unit_price
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','ETH',
    'shares', 3, 'price_per_share', 33.333333, 'order_fee', 1, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'avg_purchase_price')::numeric IS DISTINCT FROM round(101.00 / 3, 8)
     OR (SELECT unit_price FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [R1b]: normaler Kauf: Einstand 101.00/3, kein unit_price erwartet, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS [R1b normaler Kauf -> Cent-Betrag/Stueck]';

  -- [R1c] Uebernahme mit Gebuehr > 2 Nachkommastellen (Krypto-Prozentgebuehr): Gebuehr auf Cent, kein CHECK-RAISE
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','ADA',
    'shares', 2, 'price_per_share', 5.002, 'order_fee', 0.004, 'transaction_date', CURRENT_DATE::text, 'existing_position', true)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT order_fee::text || '|' || amount::text FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int) IS DISTINCT FROM '0.00|-10.00' THEN
    RAISE EXCEPTION 'FAIL [R1c]: Gebuehr 0.004 -> 0.00, Betrag -10.00 erwartet, got %', v_res;
  END IF;
  -- Kurs < 5e-9 rundet auf 0 -> ok:false (nicht still ein 0-Kurs)
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','SHIB',
    'shares', 1, 'price_per_share', 0.000000004, 'order_fee', 1, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [R1c tiny]: Kurs 4e-9 -> ok:false, got %', v_res; END IF;
  RAISE NOTICE 'PASS [R1c Gebuehr auf Cent, Mini-Kurs abgelehnt]';

  -- [R2] Mini-Kauf, > 8 Stueck-Nachkommastellen, Verkauf mit Gebuehr >= Erloes -> ok:false ohne Write
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','DOGE',
    'shares', 0.00000001, 'price_per_share', 100, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE symbol = 'DOGE') THEN
    RAISE EXCEPTION 'FAIL [R2 mini]: ok:false ohne Write erwartet, got %', v_res;
  END IF;
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'symbol','SOL',
    'shares', 0.123456789, 'price_per_share', 100, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [R2 stueck]: >8 Nachkommastellen -> ok:false, got %', v_res; END IF;
  SELECT id INTO v_hold FROM finance.depot_holdings WHERE account_id = v_depot AND symbol = 'ETH';
  SELECT finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_cash, 'holding_id', v_hold, 'shares', 0.01,
    'price_per_share', 30, 'order_fee', 1, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [R2 sell]: Gebuehr >= Erloes -> ok:false, got %', v_res; END IF;
  SELECT finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_cash, 'holding_id', v_hold, 'shares', 0.0000000001,
    'price_per_share', 30, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [R2 sell stueck]: ok:false erwartet, got %', v_res; END IF;
  -- Erloes-Rueckgabe = GEBUCHTER Cent-Betrag (vorher ungerundet 99.999999 bei gebuchten 100.00)
  SELECT finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_cash, 'holding_id', v_hold, 'shares', 3,
    'price_per_share', 33.333333, 'transaction_date', CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'proceeds')::numeric IS DISTINCT FROM 100.00
     OR (SELECT amount FROM finance.transactions WHERE id = (v_res->>'sell_tx_id')::int) IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL [R2 proceeds]: gebuchte 100.00 erwartet, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS [R2 Mini-Kauf / >8 Stellen / Gebuehr >= Erloes -> ok:false; proceeds = gebuchter Betrag]';

  -- [R3] CHECK-Backstop: unit_price passt nicht zum Betrag
  v_ok := false;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, unit_price)
    VALUES (v_cash, -100, CURRENT_DATE, 'buy', v_hold, 1, 0, 99);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [R3]: unit_price 99 bei Betrag 100 haette den CHECK verletzen muessen'; END IF;
  RAISE NOTICE 'PASS [R3 CHECK unit_price ~ Betrag]';

  -- [R5] fn_to_eur_unrounded / fn_to_eur
  PERFORM finance.fn_ensure_currency('USD');
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','USD', 1.077, '2026-01-01')
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
  IF finance.fn_to_eur_unrounded(0.20, 'USD') IS DISTINCT FROM 0.20 / 1.077
     OR finance.fn_to_eur(0.20, 'USD') IS DISTINCT FROM 0.19
     OR finance.fn_to_eur(1.23456, 'EUR') IS DISTINCT FROM 1.23456
     OR finance.fn_to_eur_unrounded(5, 'XAU') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [R5]: ungerundet % / gerundet % / EUR % / ohne Kurs %',
      finance.fn_to_eur_unrounded(0.20, 'USD'), finance.fn_to_eur(0.20, 'USD'), finance.fn_to_eur(1.23456, 'EUR'),
      finance.fn_to_eur_unrounded(5, 'XAU');
  END IF;
  RAISE NOTICE 'PASS [R5 fn_to_eur_unrounded ungerundet, fn_to_eur unveraendert]';
END $$;

-- [R4] V019-Backfill-Logik (KOPIE von packages/finance/db/migrations/V019__takeover_unit_price.sql, Schritt 1)
DO $$
DECLARE
  v_cash INT; v_depot INT; v_h INT; v_g UUID; v_t1 INT; v_t2 INT; v_t3 INT; v_t4 INT;
  r RECORD; v_price NUMERIC;
BEGIN
  INSERT INTO finance.accounts (name, account_type) VALUES ('__r4 cash__','cash') RETURNING id INTO v_cash;
  INSERT INTO finance.accounts (name, account_type, settlement_account_id) VALUES ('__r4 dep__','crypto_depot', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.depot_holdings (account_id, symbol, name) VALUES (v_depot, 'BTC', 'BTC') RETURNING id INTO v_h;
  -- Altzeilen wie vor dem Rundungs-Paket (unit_price NULL), je mit Gegenbuchung in derselben group_id
  v_g := gen_random_uuid();
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description, group_id)
  VALUES (v_cash, -3322.20, CURRENT_DATE, 'buy', v_h, 0.06127493, 0, 'Kauf 0.06127493 BTC @ 54218 (Gebühr 0)', v_g) RETURNING id INTO v_t1;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES (v_cash, 3322.20, CURRENT_DATE, 'position_takeover', v_g);
  v_g := gen_random_uuid();
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description, group_id)
  VALUES (v_cash, -101.00, CURRENT_DATE, 'buy', v_h, 1, 1, 'Kauf 1 A@B @ 100 (Gebuehr 1)', v_g) RETURNING id INTO v_t2;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES (v_cash, 101.00, CURRENT_DATE, 'position_takeover', v_g);
  v_g := gen_random_uuid();
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description, group_id)
  VALUES (v_cash, -50.00, CURRENT_DATE, 'buy', v_h, 2, NULL, 'Kauf 2 BTC @ 25 (Gebühr )', v_g) RETURNING id INTO v_t3;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES (v_cash, 50.00, CURRENT_DATE, 'position_takeover', v_g);
  v_g := gen_random_uuid();   -- Beschreibung passt NICHT zum Betrag -> bleibt NULL
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description, group_id)
  VALUES (v_cash, -70.00, CURRENT_DATE, 'buy', v_h, 1, 0, 'Kauf 1 BTC @ 60 (Gebühr 0)', v_g) RETURNING id INTO v_t4;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES (v_cash, 70.00, CURRENT_DATE, 'position_takeover', v_g);

  -- ===== Logik-Kopie V019 Schritt 1 =====
  FOR r IN
      SELECT t.id, t.shares, t.order_fee, t.amount, t.description
      FROM finance.transactions t
      WHERE t.category::text = 'buy' AND t.unit_price IS NULL AND t.shares > 0 AND t.group_id IS NOT NULL
        AND EXISTS (SELECT 1 FROM finance.transactions g WHERE g.group_id = t.group_id AND g.category::text = 'position_takeover')
  LOOP
      v_price := NULL;
      BEGIN
          v_price := round(((regexp_match(r.description, ' @ ([^ ]+) \(Geb'))[1])::numeric, 8);
      EXCEPTION WHEN others THEN v_price := NULL;
      END;
      IF v_price > 0 AND round(r.shares * v_price + COALESCE(r.order_fee, 0), 2) = -r.amount THEN
          UPDATE finance.transactions SET unit_price = v_price WHERE id = r.id;
      END IF;
  END LOOP;
  -- ===== Ende Kopie =====

  IF (SELECT unit_price FROM finance.transactions WHERE id = v_t1) IS DISTINCT FROM 54218
     OR (SELECT unit_price FROM finance.transactions WHERE id = v_t2) IS DISTINCT FROM 100
     OR (SELECT unit_price FROM finance.transactions WHERE id = v_t3) IS DISTINCT FROM 25
     OR (SELECT unit_price FROM finance.transactions WHERE id = v_t4) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [R4]: Backfill 54218 / 100 (Gebuehr, Symbol mit @) / 25 (leere Gebuehr) / NULL (passt nicht) erwartet';
  END IF;
  RAISE NOTICE 'PASS [R4 V019-Backfill: Gebühr/Gebuehr, leere Gebuehr, Symbol mit @, Nicht-Treffer bleibt NULL]';
END $$;

ROLLBACK;
