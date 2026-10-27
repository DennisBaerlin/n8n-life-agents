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
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 3000)) INTO v_res;
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
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 5000)) INTO v_res;
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
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 5000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3 no-op]: erwartet ok:false (delta 0), got %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_cnt <> 2 THEN RAISE EXCEPTION 'FAIL [3 no insert]: erwartet weiter 2 Zeilen, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [3: delta 0 (gleicher Betrag) -> {ok:false}, kein Insert]';

  -- ===================================================================================
  -- (4) Release: amount 0 -> delta = 0 - 5000 = -5000 angehaengt -> Σ 0 (Reserve voll freigegeben, Bestand bleibt).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 0)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 release ok]: %', v_res; END IF;
  IF (v_res->>'delta')::numeric IS DISTINCT FROM -5000 THEN RAISE EXCEPTION 'FAIL [4 delta]: erwartet -5000, got %', v_res->>'delta'; END IF;
  IF (v_res->>'reserved')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [4 reserved]: erwartet 0, got %', v_res->>'reserved'; END IF;
  SELECT sum(delta_native) INTO v_sum FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_sum IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [4 Σ]: erwartet Σ 0 nach Release, got %', v_sum; END IF;
  RAISE NOTICE 'PASS [4: amount 0 -> delta -5000 angehaengt -> Reserve freigegeben (Σ 0), Journal bleibt Audit-Spur]';

  -- Zwischenstand fuer (4b): zurueck auf 2000 fuer den negativ-Σ-Guard
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', 2000)) INTO v_res;

  -- ===================================================================================
  -- (5) Negativ-Σ-Guard: amount < 0 -> {ok:false} (eine Reserve kann nicht negativ werden).
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'account_id', v_depot, 'amount', -100)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 negativ]: erwartet ok:false (amount<0), got %', v_res; END IF;
  RAISE NOTICE 'PASS [5: amount<0 -> {ok:false} (keine negative Reserve)]';

  -- ===================================================================================
  -- (6) Kreditkonto: nicht zuordenbar -> {ok:false} (Allowlist fn_goal_earmark_account_types: Topf-Typen + Depots).
  -- ===================================================================================
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__rsv_loan__','loan','EUR','active') RETURNING id INTO v_cashacct;
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', v_goal, 'account_id', v_cashacct, 'amount', 1000)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 loan]: erwartet ok:false (Kreditkonto), got %', v_res; END IF;
  RAISE NOTICE 'PASS [6: Kreditkonto -> {ok:false}]';

  -- ===================================================================================
  -- (7) Ziel nicht gefunden -> {ok:false}.
  -- ===================================================================================
  SELECT finance.fn_book_savings_reservation(jsonb_build_object(
    'savings_goal_id', 999999999, 'account_id', v_depot, 'amount', 1000)) INTO v_res;
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
    'savings_goal_id', v_goal2, 'account_id', v_depot, 'amount', 1500)) INTO v_res;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal2;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [9 setup]: erwartet 1 Journal-Zeile, got %', v_cnt; END IF;
  DELETE FROM finance.savings_goals WHERE id = v_goal2;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal2;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [9 cascade]: erwartet 0 Journal-Zeilen nach Ziel-DELETE, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [9: DELETE Ziel -> savings_goal_reserve_entries cascadet (Reserve-Zuordnung weg, Bestand bleibt)]';

  -- (9b) Depots stehen nicht im Saldo-Waechter account_reserve_status (Marktwert-Deckung = depot_reserve_status).
  IF EXISTS (SELECT 1 FROM finance.account_reserve_status WHERE account_id = v_depot) THEN
    RAISE EXCEPTION 'FAIL [9b]: Depot darf nicht in account_reserve_status stehen (sonst Schein-Breach)'; END IF;
  RAISE NOTICE 'PASS [9b: Depot nicht im Saldo-Waechter]';
END $$;

-- ===================================================================================
-- Zweckbindung auf saldo-basierten Konten (cash/p2p/fixed_deposit): Zuordnung vorhandenen Geldes ohne Transfer.
--   (10) P2P: 3000 von 5000 zuordnen -> Journal in Kontowaehrung, free_balance 2000, Fortschritt 3000, Ziel erreicht
--   (11) zweites Ziel will 2500 auf demselben Konto -> insufficient_free_balance (frei 2000), kein Insert
--   (12) 2000 passt -> free_balance 0
--   (13) getaggtes Transfer-Geld wird angerechnet: absolut 1500 bei 1200 getaggt -> delta 300
--   (14) Freigabe auf 0 gegen getaggtes Geld -> Anteil 0, Fortschritt 0
--   (15) Saldo faellt unter die Zuordnungen: Senken ist immer erlaubt (Guard nur bei delta > 0)
--   (16) Fremdwaehrungskonto: Journal in USD, Waechter vergleicht nativ
--   (17) abgebrochenes Ziel blockiert den freien Saldo nicht mehr
-- ===================================================================================
DO $$
DECLARE
  v_p2p INT; v_cash INT; v_usd INT; v_ga INT; v_gb INT; v_gc INT; v_gd INT; v_res JSONB;
  v_cnt INT; v_ccy TEXT; v_res_amt NUMERIC; v_cur NUMERIC; v_breach BOOLEAN;
BEGIN
  v_p2p  := (finance.fn_create_account('{"name":"__rsv2_p2p__","account_type":"p2p","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_cash := (finance.fn_create_account('{"name":"__rsv2_cash__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv2_a__', 3000, current_date + 400, 'active') RETURNING id INTO v_ga;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv2_b__', 9000, current_date + 400, 'active') RETURNING id INTO v_gb;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv2_c__', 9000, current_date + 400, 'active') RETURNING id INTO v_gc;

  -- (10)
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_ga, 'account_id', v_p2p, 'amount', 3000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'reserved')::numeric IS DISTINCT FROM 3000
     OR (v_res->>'delta')::numeric IS DISTINCT FROM 3000 OR (v_res->>'free_balance')::numeric IS DISTINCT FROM 2000
     OR (v_res->>'current_amount')::numeric IS DISTINCT FROM 3000 OR NOT (v_res ? 'savings_goal_reached') THEN
    RAISE EXCEPTION 'FAIL [10 p2p]: %', v_res; END IF;
  SELECT currency INTO v_ccy FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_ga;
  IF v_ccy IS DISTINCT FROM 'EUR' THEN RAISE EXCEPTION 'FAIL [10 ccy]: %', v_ccy; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_ga;
  SELECT reserved, breach INTO v_res_amt, v_breach FROM finance.account_reserve_status WHERE account_id = v_p2p;
  IF v_cur IS DISTINCT FROM 3000 OR v_res_amt IS DISTINCT FROM 3000 OR v_breach THEN
    RAISE EXCEPTION 'FAIL [10 views]: progress % reserved % breach %', v_cur, v_res_amt, v_breach; END IF;
  RAISE NOTICE 'PASS [10: P2P-Zuordnung 3000, frei 2000, Fortschritt 3000, Waechter reserved 3000]';

  -- (11)
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gb, 'account_id', v_p2p, 'amount', 2500));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'code' IS DISTINCT FROM 'insufficient_free_balance'
     OR (v_res->>'free')::numeric IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'FAIL [11 guard]: %', v_res; END IF;
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_gb;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [11 no insert]: %', v_cnt; END IF;
  RAISE NOTICE 'PASS [11: Ueberzuordnung -> insufficient_free_balance, frei 2000]';

  -- (12)
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gb, 'account_id', v_p2p, 'amount', 2000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'free_balance')::numeric IS DISTINCT FROM 0
     OR v_res ? 'savings_goal_reached' THEN
    RAISE EXCEPTION 'FAIL [12]: %', v_res; END IF;
  RAISE NOTICE 'PASS [12: genau passend -> frei 0, kein erreicht-Hinweis bei 2000/9000]';

  -- (13) 1200 getaggtes Transfer-Geld auf dem Cash-Konto
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_cash, 1200, current_date - 3, 'transfer', v_gc, gen_random_uuid());
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gc, 'account_id', v_cash, 'amount', 1500));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'code' IS DISTINCT FROM 'insufficient_free_balance' THEN
    RAISE EXCEPTION 'FAIL [13 guard tagged]: Saldo 1200 traegt keine 1500, got %', v_res; END IF;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id)
    VALUES (v_cash, 800, current_date - 2, 'other', gen_random_uuid());
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gc, 'account_id', v_cash, 'amount', 1500));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'delta')::numeric IS DISTINCT FROM 300
     OR (v_res->>'reserved')::numeric IS DISTINCT FROM 1500 OR (v_res->>'free_balance')::numeric IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL [13 anrechnen]: %', v_res; END IF;
  RAISE NOTICE 'PASS [13: 1200 getaggt angerechnet -> delta 300, reserved 1500, frei 500]';

  -- (14)
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gc, 'account_id', v_cash, 'amount', 0));
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_gc;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'delta')::numeric IS DISTINCT FROM -1500 OR v_cur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [14 release vs tags]: % / progress %', v_res, v_cur; END IF;
  RAISE NOTICE 'PASS [14: Freigabe auf 0 gegen Tags -> delta -1500, Fortschritt 0]';

  -- (15) P2P-Saldo faellt von 5000 auf 3000 (zugeordnet 5000) -> Senken auf 2000 erlaubt
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id)
    VALUES (v_p2p, -2000, current_date - 1, 'other', gen_random_uuid());
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_ga, 'account_id', v_p2p, 'amount', 2000));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'delta')::numeric IS DISTINCT FROM -1000 THEN
    RAISE EXCEPTION 'FAIL [15 senken immer erlaubt]: %', v_res; END IF;
  RAISE NOTICE 'PASS [15: Senken trotz Ueberzuordnung erlaubt]';

  -- (16) Fremdwaehrung
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  v_usd := (finance.fn_create_account('{"name":"__rsv2_usd__","account_type":"cash","currency":"USD","opening_balance":1000}'::jsonb)->>'account_id')::int;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gc, 'account_id', v_usd, 'amount', 400));
  SELECT currency INTO v_ccy FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_gc AND account_id = v_usd;
  SELECT reserved INTO v_res_amt FROM finance.account_reserve_status WHERE account_id = v_usd;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_ccy IS DISTINCT FROM 'USD' OR v_res_amt IS DISTINCT FROM 400
     OR (v_res->>'free_balance')::numeric IS DISTINCT FROM 600 THEN
    RAISE EXCEPTION 'FAIL [16 usd]: % / ccy % / reserved %', v_res, v_ccy, v_res_amt; END IF;
  RAISE NOTICE 'PASS [16: USD-Zuordnung nativ, Waechter reserved 400 USD, frei 600]';

  -- (17) Ziel b abbrechen -> seine 2000 blockieren den P2P-Saldo nicht mehr (Saldo 3000, aktiv zugeordnet nur a=2000)
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = v_gb;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rsv2_d__', 900, current_date + 400, 'active') RETURNING id INTO v_gd;
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gd, 'account_id', v_p2p, 'amount', 900));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'free_balance')::numeric IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL [17 cancelled frees]: %', v_res; END IF;
  RAISE NOTICE 'PASS [17: abgebrochenes Ziel gibt den Saldo frei]';

  -- (18) einem abgebrochenen Ziel kann nichts mehr zugeordnet werden (die Guards zaehlen nur aktive Ziele)
  v_res := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gb, 'account_id', v_p2p, 'amount', 2500));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [18 nicht aktives Ziel]: %', v_res; END IF;
  RAISE NOTICE 'PASS [18: abgebrochenes Ziel -> ok:false]';
END $$;

ROLLBACK;
