-- tests/db/finance/test_fn_app_holding_transactions.sql
-- finance.fn_app_holding_transactions(holding_id) — Buchungs-Zeilen einer Depot-Position fuer das Aufklappen der Mini-App.
--   1) die 12 neuesten Buchungen zuerst, Stueckpreis = |Betrag| / Stueck (inkl. Gebuehr), Betrag positiv in der
--      Waehrung des Buchungskontos; danach „2 aeltere Buchungen".
--   2) Verkauf und Dividende (eigene Texte), Bestandsuebernahme mit unit_price nimmt den genannten Stueckpreis.
--   3) ohne Buchungen -> [] (keine „aeltere"-Zeile); keine IDs, keine Kontonamen.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_dep INT; v_h INT; v_h2 INT;
  v jsonb; v_labels text[];
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__ahtx_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__ahtx_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_dep, 'AHT00000001', 'AHTX1', '__ahtx_etf__', 0, NULL, 'EUR') RETURNING id INTO v_h;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_dep, 'AHT00000002', 'AHTX2', '__ahtx_leer__', 0, NULL, 'EUR') RETURNING id INTO v_h2;
  -- 14 Kaeufe je 2 Stueck fuer 25,00 (taeglich, der neueste vor 6 Tagen)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, group_id)
    SELECT v_giro, -25.00, current_date - (20 - k), 'buy', v_h, 2, gen_random_uuid() FROM generate_series(1, 14) k;

  -- ===== 1) 12 neueste + „aeltere" =====
  v := finance.fn_app_holding_transactions(v_h);
  SELECT array_agg(d->'label'->>'value' ORDER BY o) INTO v_labels FROM jsonb_array_elements(v) WITH ORDINALITY AS t(d, o);
  IF cardinality(v_labels) <> 13 OR v_labels[13] <> 'finance.app.depot.tx_more' THEN
    RAISE EXCEPTION 'FAIL [1a] 12 Buchungen + „aeltere", got %', v_labels; END IF;
  IF v->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.tx_buy', jsonb_build_object(
          'date', core.fn_ui_date(current_date - 6), 'shares', core.fn_ui_num(2, 0), 'price', core.fn_ui_money(12.50, 'EUR'))),
        'value', core.fn_ui_money(25, 'EUR')) THEN
    RAISE EXCEPTION 'FAIL [1b] neueste Buchung zuerst, Stueckpreis = |Betrag| / Stueck, got %', v->0; END IF;
  IF v->11->'label'->'params'->'date' <> core.fn_ui_date(current_date - 17) THEN
    RAISE EXCEPTION 'FAIL [1c] 12. Zeile = 12. neueste Buchung, got %', v->11; END IF;
  IF v->12 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.tx_more', jsonb_build_object('count', core.fn_ui_num(2, 0))), 'value', NULL) THEN
    RAISE EXCEPTION 'FAIL [1d] „2 aeltere Buchungen", got %', v->12; END IF;
  RAISE NOTICE 'PASS [1] 12 neueste Buchungen (Stueckpreis aus Betrag) + „2 aeltere"';

  -- ===== 2) Verkauf, Dividende, Bestandsuebernahme mit unit_price =====
  DELETE FROM finance.transactions WHERE holding_id = v_h;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id)
    VALUES (v_giro, -100.00, current_date - 3, 'buy', v_h, 3, 33.33333333, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, group_id)
    VALUES (v_giro, 40.00, current_date - 2, 'sell', v_h, -1, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, group_id)
    VALUES (v_giro, 1.50, current_date - 1, 'dividend', v_h, gen_random_uuid());
  v := finance.fn_app_holding_transactions(v_h);
  IF jsonb_array_length(v) <> 3
     OR v->0 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.tx_dividend', jsonb_build_object(
          'date', core.fn_ui_date(current_date - 1))), 'value', core.fn_ui_money(1.50, 'EUR'))
     OR v->1 <> jsonb_build_object('label', core.fn_ui_tpl('finance.app.depot.tx_sell', jsonb_build_object(
          'date', core.fn_ui_date(current_date - 2), 'shares', core.fn_ui_num(1, 0), 'price', core.fn_ui_money(40, 'EUR'))),
          'value', core.fn_ui_money(40, 'EUR'))
     OR v->2->'label'->'params'->'price' <> core.fn_ui_money(33.33333333, 'EUR') THEN
    RAISE EXCEPTION 'FAIL [2] Dividende, Verkauf (Stueck positiv), Uebernahme mit unit_price, got %', v; END IF;
  RAISE NOTICE 'PASS [2] Verkauf, Dividende, Bestandsuebernahme mit genanntem Stueckpreis';

  -- ===== 3) ohne Buchungen; keine IDs/Kontonamen =====
  IF finance.fn_app_holding_transactions(v_h2) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [3a] ohne Buchungen -> []'; END IF;
  IF v::text ~ '"[a-z_]*id"\s*:' OR v::text LIKE '%__ahtx_%' THEN
    RAISE EXCEPTION 'FAIL [3b] Zeilen tragen eine ID oder einen Kontonamen: %', v; END IF;
  RAISE NOTICE 'PASS [3] leer -> []; keine IDs, keine Kontonamen';
END $$;

DO $$
BEGIN
  IF has_function_privilege('public', 'finance.fn_app_holding_transactions(int)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [4] PUBLIC darf fn_app_holding_transactions nicht ausfuehren'; END IF;
  RAISE NOTICE 'PASS [4] kein EXECUTE fuer PUBLIC';
END $$;
ROLLBACK;
