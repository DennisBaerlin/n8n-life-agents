-- tests/db/finance/test_fn_book_takeover_pair.sql
-- Testet den internen Paar-Baustein der Bestandsuebernahme: Kauf + Gegenbuchung in EINER group_id, Verrechnungskonto
-- netto 0, korrigierbare Eingaben -> {ok:false} ohne Write; plus fn_unit_price_from_total (Stueckpreis aus Gesamtbetrag).
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_settle INT; v_depot INT; v_hid INT; v_group UUID := gen_random_uuid(); v_cnt INT;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__tp_settle__","account_type":"cash","opening_balance":321.09}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__tp_depot__','account_type','stocks_depot',
               'settlement_id', v_settle))->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name) VALUES (v_depot, 'IE00BFMXXD54', 'VUAA', 'S&P 500')
  RETURNING id INTO v_hid;

  -- TEST 1: zwei Tranchen in derselben group_id -> 4 Zeilen, Saldo unveraendert, Einstand gewichtet aus unit_price
  v_res := finance.fn_book_takeover_pair(v_hid, v_settle, 10, 20.123456789, 1, DATE '2026-05-04', v_group, 'VUAA');
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'buy_tx_id') IS NULL THEN
    RAISE EXCEPTION 'FAIL takeover_pair [1a]: %', v_res; END IF;
  v_res := finance.fn_book_takeover_pair(v_hid, v_settle, 5, 22, NULL, DATE '2026-05-11', v_group, 'VUAA');
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE group_id = v_group;
  IF v_cnt <> 4 OR finance.fn_get_balance(v_settle) IS DISTINCT FROM 321.09
     OR (SELECT shares FROM finance.depot_holdings WHERE id = v_hid) IS DISTINCT FROM 15
     OR (SELECT unit_price FROM finance.transactions WHERE id = (v_res->>'buy_tx_id')::int) IS DISTINCT FROM 22 THEN
    RAISE EXCEPTION 'FAIL takeover_pair [1b]: rows % balance % res %', v_cnt, finance.fn_get_balance(v_settle), v_res; END IF;
  IF (SELECT unit_price FROM finance.transactions WHERE group_id = v_group AND category = 'buy' ORDER BY id LIMIT 1)
     IS DISTINCT FROM 20.12345679 THEN
    RAISE EXCEPTION 'FAIL takeover_pair [1c]: Kurs muss auf 8 Stellen gerundet sein'; END IF;
  RAISE NOTICE 'PASS takeover_pair [1 zwei Tranchen, eine group_id, Saldo unveraendert, Kurs 8 Stellen]';

  -- TEST 2: korrigierbare Eingaben -> ok:false, kein Write
  SELECT count(*) INTO v_cnt FROM finance.transactions WHERE account_id = v_settle;
  IF (finance.fn_book_takeover_pair(v_hid, v_settle, 0, 10, 0, CURRENT_DATE, v_group, 'VUAA')->>'ok')::boolean
     OR (finance.fn_book_takeover_pair(v_hid, v_settle, 1, 0, 0, CURRENT_DATE, v_group, 'VUAA')->>'ok')::boolean
     OR (finance.fn_book_takeover_pair(v_hid, v_settle, 1, 10, -1, CURRENT_DATE, v_group, 'VUAA')->>'ok')::boolean
     OR (finance.fn_book_takeover_pair(v_hid, v_settle, 0.000000001, 10, 0, CURRENT_DATE, v_group, 'VUAA')->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL takeover_pair [2]: ungueltige Eingaben muessen ok:false liefern'; END IF;
  IF (SELECT count(*) FROM finance.transactions WHERE account_id = v_settle) <> v_cnt THEN
    RAISE EXCEPTION 'FAIL takeover_pair [2]: abgelehnte Eingabe hat geschrieben'; END IF;
  RAISE NOTICE 'PASS takeover_pair [2 Stueck 0 / Kurs 0 / Gebuehr negativ / 9 Stueck-Stellen -> ok:false ohne Write]';

  -- TEST 3: fn_unit_price_from_total
  IF finance.fn_unit_price_from_total(25000, 1875.12345) IS DISTINCT FROM round(25000 / 1875.12345, 8)
     OR finance.fn_unit_price_from_total(100, 0) IS NOT NULL
     OR finance.fn_unit_price_from_total(NULL, 3) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL unit_price_from_total [3]'; END IF;
  RAISE NOTICE 'PASS unit_price_from_total [3 Gesamt/Stueck auf 8 Stellen, 0 Stueck/NULL -> NULL]';
  -- TEST 4: fn_parse_numeric_or_null (freie Tool-Eingabe, nie ein Cast-RAISE)
  IF finance.fn_parse_numeric_or_null('1.234,50', true) IS DISTINCT FROM 1234.50
     OR finance.fn_parse_numeric_or_null('0.125', false) IS DISTINCT FROM 0.125
     OR finance.fn_parse_numeric_or_null('etwa tausend', true) IS NOT NULL
     OR finance.fn_parse_numeric_or_null('', true) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL parse_numeric_or_null [4]'; END IF;
  RAISE NOTICE 'PASS parse_numeric_or_null [4 deutsch/plain geparst, unlesbar/leer -> NULL]';
END $$;

ROLLBACK;
