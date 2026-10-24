-- tests/db/finance/test_fn_book_savings_reservation.sql
-- WS-B Stufe 1 (Phase S): finance.fn_book_savings_reservation — der Depot-Anteil einer Sparziel-Reserve als
-- APPEND-ONLY Journal (savings_goal_reserve_entries). Input = ABSOLUTER Ziel-Betrag (amount) fuer (Ziel, Depot);
-- die fn rechnet delta = amount - COALESCE(SUM(journal),0) und haengt EINE manual-Zeile an (kein LLM-Rechnen,
-- absolut-rein -> delta-append -> strukturell driftfrei). Marktwert ist Deckel/Deckung, NIE die gespeicherte
-- Reserve. Korrigierbar (kein RAISE): nicht-Depot-Konto / Ziel-Konto nicht gefunden / delta=0 (no-op) /
-- amount<0 (negative Reserve). Post-State {reserved, delta, market_value, shortfall} DB-berechnet.
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_settle INT; v_depot INT; v_cashacct INT; v_goal INT; v_goal2 INT;
  v_cnt INT; v_sum NUMERIC; v_cur NUMERIC; v_topf INT;
BEGIN
  -- Setup: Verrechnungskonto + Depot + ein gehaltenes Wertpapier mit Kurs (Marktwert 600) + ein Cash-Topf.
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rsv_settle__','cash','EUR','active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__rsv_depot__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rsv_topf__','cash','EUR','active') RETURNING id INTO v_topf;
  v_cashacct := v_settle;   -- cash-Konto als "nicht-Depot"-Negativfall
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'RSVTEST', 'Reserve Testwert', 5, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('RSVTEST', 120, 'EUR', current_date);  -- Marktwert 5*120 = 600

  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv_goal__', 8000, current_date + 365, 'active') RETURNING id INTO v_goal;

  -- ===================================================================================
  -- (1) Erstzuordnung: amount 3000 -> delta 3000 (oldΣ 0) -> EINE Journal-Zeile, reserved 3000.
  --     Marktwert 600 < reserviert 3000 -> shortfall 2400 (DB-berechnet, Post-State).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', 3000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1 ok]: %', v_res; END IF;
  IF (v_res->>'reserved')::numeric IS DISTINCT FROM 3000 THEN RAISE EXCEPTION 'FAIL [1 reserved]: erwartet 3000, got %', v_res->>'reserved'; END IF;
  IF (v_res->>'delta')::numeric IS DISTINCT FROM 3000 THEN RAISE EXCEPTION 'FAIL [1 delta]: erwartet 3000, got %', v_res->>'delta'; END IF;
  IF (v_res->>'market_value')::numeric IS DISTINCT FROM 600 THEN RAISE EXCEPTION 'FAIL [1 market_value]: erwartet 600, got %', v_res->>'market_value'; END IF;
  IF (v_res->>'shortfall')::numeric IS DISTINCT FROM 2400 THEN RAISE EXCEPTION 'FAIL [1 shortfall]: erwartet 2400 (3000-600), got %', v_res->>'shortfall'; END IF;
  SELECT count(*), sum(delta_native) INTO v_cnt, v_sum FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_cnt <> 1 OR v_sum IS DISTINCT FROM 3000 THEN RAISE EXCEPTION 'FAIL [1 journal]: erwartet 1 Zeile / Σ 3000, got % / %', v_cnt, v_sum; END IF;
  RAISE NOTICE 'PASS [1: amount 3000 -> delta-append 3000, reserved 3000, mv 600, shortfall 2400]';

  -- ===================================================================================
  -- (2) Erhoehung auf absolut 5000 -> delta = 5000 - 3000 = 2000 angehaengt (NIE UPDATE) -> 2 Zeilen, Σ 5000.
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', 5000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [2 ok]: %', v_res; END IF;
  IF (v_res->>'delta')::numeric IS DISTINCT FROM 2000 THEN RAISE EXCEPTION 'FAIL [2 delta]: erwartet 2000 (5000-3000), got %', v_res->>'delta'; END IF;
  IF (v_res->>'reserved')::numeric IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 'FAIL [2 reserved]: erwartet 5000, got %', v_res->>'reserved'; END IF;
  SELECT count(*), sum(delta_native) INTO v_cnt, v_sum FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_cnt <> 2 OR v_sum IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 'FAIL [2 append]: erwartet 2 Zeilen / Σ 5000 (kein UPDATE), got % / %', v_cnt, v_sum; END IF;
  RAISE NOTICE 'PASS [2: absolut 5000 -> delta 2000 ANGEHAENGT (append-only), 2 Zeilen, Σ 5000]';

  -- ===================================================================================
  -- (3) No-op: derselbe absolute Betrag 5000 -> delta 0 -> {ok:false} (kein Insert, CHECK-Backstop nie getrippt).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', 5000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3 no-op]: erwartet ok:false (delta 0), got %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [3 no insert]: erwartet weiter 2 Zeilen, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [3: delta 0 (gleicher Betrag) -> {ok:false}, kein Insert]';

  -- ===================================================================================
  -- (4) Release: amount 0 -> delta = 0 - 5000 = -5000 angehaengt -> Σ 0 (Reserve voll freigegeben, Bestand bleibt).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', 0)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 release ok]: %', v_res; END IF;
  IF (v_res->>'delta')::numeric IS DISTINCT FROM -5000 THEN RAISE EXCEPTION 'FAIL [4 delta]: erwartet -5000, got %', v_res->>'delta'; END IF;
  IF (v_res->>'reserved')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [4 reserved]: erwartet 0, got %', v_res->>'reserved'; END IF;
  SELECT sum(delta_native) INTO v_sum FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_sum IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [4 Σ]: erwartet Σ 0 nach Release, got %', v_sum; END IF;
  RAISE NOTICE 'PASS [4: amount 0 -> delta -5000 angehaengt -> Reserve freigegeben (Σ 0), Journal bleibt Audit-Spur]';

  -- Zwischenstand fuer (4b): zurueck auf 2000 fuer den negativ-Σ-Guard
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', 2000)) INTO v_res;

  -- ===================================================================================
  -- (5) Negativ-Σ-Guard: amount < 0 -> {ok:false} (eine Reserve kann nicht negativ werden).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_depot, 'amount', -100)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 negativ]: erwartet ok:false (amount<0), got %', v_res; END IF;
  RAISE NOTICE 'PASS [5: amount<0 -> {ok:false} (keine negative Reserve)]';

  -- ===================================================================================
  -- (6) Nicht-Depot-Konto: ein Cash-Konto -> {ok:false} (Reserve-Journal nur gegen Depot-Marktwert).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'depot_account_id', v_cashacct, 'amount', 1000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 non-depot]: erwartet ok:false (Cash-Konto), got %', v_res; END IF;
  RAISE NOTICE 'PASS [6: Nicht-Depot-Konto -> {ok:false}]';

  -- ===================================================================================
  -- (7) Ziel nicht gefunden -> {ok:false}.
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', 999999999, 'depot_account_id', v_depot, 'amount', 1000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [7 goal]: erwartet ok:false (Ziel fehlt), got %', v_res; END IF;
  RAISE NOTICE 'PASS [7: Ziel nicht gefunden -> {ok:false}]';

  -- ===================================================================================
  -- (8) Fortschritts-Kopplung: current_amount = Cash-Tag + Σ Journal. Cash-Tag +300, Journal-Σ 2000 -> 2300.
  -- ===================================================================================
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_topf, 300, current_date - 5, 'transfer', v_goal, gen_random_uuid());
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 2300 THEN RAISE EXCEPTION 'FAIL [8 progress]: erwartet 2300 (300 Cash + 2000 Journal), got %', v_cur; END IF;
  RAISE NOTICE 'PASS [8: savings_goal_progress.current_amount = Cash 300 + Depot-Journal 2000 = 2300]';

  -- ===================================================================================
  -- (9) CASCADE: Ziel hart loeschen (kein getaggtes Tx -> hier direkt) -> Journal-Zeilen fallen mit.
  --     (Ueber den Cash-Tag verhindert fn_close den Hard-Delete; hier ein anderes Ziel ohne Tx fuer die CASCADE-Probe.)
  -- ===================================================================================
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv_goal2__', 4000, current_date + 365, 'active') RETURNING id INTO v_goal2;
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal2, 'depot_account_id', v_depot, 'amount', 1500)) INTO v_res;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal2;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [9 setup]: erwartet 1 Journal-Zeile, got %', v_cnt; END IF;
  DELETE FROM finance.savings_goals WHERE id = v_goal2;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal2;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [9 cascade]: erwartet 0 Journal-Zeilen nach Ziel-DELETE, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [9: DELETE Ziel -> savings_goal_reserve_entries cascadet (Reserve-Zuordnung weg, Bestand bleibt)]';
END $$;

ROLLBACK;
