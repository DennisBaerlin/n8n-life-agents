-- tests/db/finance/test_fn_reserve_breach.sql
-- WS-C2 (Phase S): proaktiver Reserve-Waechter. finance.account_reserve_status (per-Konto balance/reserved/
-- shortfall/breach) + finance.fn_reserve_breach(account_id)->jsonb (NULL bei kein-Breach).
-- Reserviert je Konto = SUM(transactions.amount WHERE savings_goal_id) ueber AKTIVE Ziele, in Konto-Native-
-- Waehrung. Breach = reserved>0 AND balance<reserved. Selbst-korrigierend: eine GETAGGTE Entnahme senkt Saldo
-- UND reserviert gleich -> kein Breach; nur eine UN-getaggte Belastung drueckt den Saldo unter die Reserve.
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_a INT; v_b INT; v_c INT; v_usd INT;
  v_gA INT; v_gB INT; v_gC INT; v_gUSD INT; v_gComp INT;
  v_bal NUMERIC; v_rsv NUMERIC; v_short NUMERIC; v_breach BOOLEAN; v_cur CHAR(3);
  v_br JSONB;
BEGIN
  -- ===================================================================================
  -- Konto A — NICHT im Breach: Reserve +500 (getaggt) + Einnahme +1000 (un-getaggt) -> Saldo 1500, reserviert 500.
  -- ===================================================================================
  SELECT finance.fn_create_account('{"name":"__rb_a__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_a := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gA__', 5000, current_date + 365, 'active') RETURNING id INTO v_gA;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_a,  500, current_date - 30, 'transfer', v_gA, gen_random_uuid()),   -- Reserve-Zufluss (getaggt)
    (v_a, 1000, current_date - 20, 'other',    NULL, NULL);   -- Einnahme (un-getaggt)

  SELECT balance, reserved, shortfall, breach INTO v_bal, v_rsv, v_short, v_breach
  FROM finance.account_reserve_status WHERE account_id = v_a;
  IF v_bal IS DISTINCT FROM 1500 OR v_rsv IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL [A view]: balance=% reserved=% (erwartet 1500/500)', v_bal, v_rsv; END IF;
  IF v_breach IS DISTINCT FROM false OR v_short IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [A breach]: breach=% shortfall=% (Saldo deckt Reserve -> kein Breach)', v_breach, v_short; END IF;
  IF finance.fn_reserve_breach(v_a) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [A fn]: fn_reserve_breach muss NULL liefern (kein Breach), got %', finance.fn_reserve_breach(v_a); END IF;
  RAISE NOTICE 'PASS [A: Saldo 1500 >= reserviert 500 -> kein Breach, fn NULL]';

  -- ===================================================================================
  -- Konto B — IM Breach: Reserve +500 (getaggt) + Ausgabe -300 (un-getaggt) -> Saldo 200, reserviert 500,
  --   Fehlbetrag 300. fn liefert das Objekt mit korrektem shortfall + native Waehrung im note.
  -- ===================================================================================
  SELECT finance.fn_create_account('{"name":"__rb_b__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_b := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gB__', 5000, current_date + 365, 'active') RETURNING id INTO v_gB;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_b,  500, current_date - 30, 'transfer', v_gB, gen_random_uuid()),   -- Reserve-Zufluss
    (v_b, -300, current_date - 10, 'other',    NULL, NULL);   -- un-getaggte Ausgabe -> greift in die Reserve

  SELECT balance, reserved, shortfall, breach INTO v_bal, v_rsv, v_short, v_breach
  FROM finance.account_reserve_status WHERE account_id = v_b;
  IF v_bal IS DISTINCT FROM 200 OR v_rsv IS DISTINCT FROM 500 OR v_short IS DISTINCT FROM 300 OR v_breach IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [B view]: balance=% reserved=% shortfall=% breach=% (erwartet 200/500/300/true)', v_bal, v_rsv, v_short, v_breach; END IF;
  v_br := finance.fn_reserve_breach(v_b);
  IF v_br IS NULL THEN RAISE EXCEPTION 'FAIL [B fn]: erwartet Breach-Objekt, got NULL'; END IF;
  IF (v_br->>'shortfall')::numeric IS DISTINCT FROM 300 OR (v_br->>'account_id')::int IS DISTINCT FROM v_b THEN
    RAISE EXCEPTION 'FAIL [B fn]: shortfall/account_id falsch: %', v_br; END IF;
  IF (v_br->>'note') NOT LIKE '%EUR%' THEN RAISE EXCEPTION 'FAIL [B note]: native Waehrung EUR fehlt im note: %', v_br->>'note'; END IF;
  RAISE NOTICE 'PASS [B: un-getaggte Ausgabe drueckt Saldo 200 unter Reserve 500 -> Breach, Fehlbetrag 300]';

  -- ===================================================================================
  -- Konto C — reserved=0-Guard: nur un-getaggte Buchungen, Saldo sogar NEGATIV -> KEIN Breach (reserved>0-Guard).
  -- ===================================================================================
  SELECT finance.fn_create_account('{"name":"__rb_c__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_c := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id) VALUES
    (v_c, -100, current_date - 5, 'other', NULL);
  SELECT reserved, breach INTO v_rsv, v_breach FROM finance.account_reserve_status WHERE account_id = v_c;
  IF v_rsv IS DISTINCT FROM 0 OR v_breach IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [C]: reserved=% breach=% (kein Tag -> reserved 0 -> nie Breach, auch bei Negativsaldo)', v_rsv, v_breach; END IF;
  IF finance.fn_reserve_breach(v_c) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [C fn]: ohne Reserve kein Breach'; END IF;
  RAISE NOTICE 'PASS [C: reserved=0 -> kein Breach trotz Negativsaldo (reserved>0-Guard)]';

  -- Multi-Konto-Isolation: Konto B im Breach, A/C nicht -> account_reserve_status liefert genau die richtige Zeile.
  IF (SELECT count(*) FROM finance.account_reserve_status WHERE account_id IN (v_a,v_b,v_c) AND breach) <> 1 THEN
    RAISE EXCEPTION 'FAIL [Isolation]: erwartet GENAU 1 Konto im Breach (B), got %',
      (SELECT count(*) FROM finance.account_reserve_status WHERE account_id IN (v_a,v_b,v_c) AND breach); END IF;
  RAISE NOTICE 'PASS [Isolation: nur Konto B im Breach, A/C unberuehrt]';

  -- ===================================================================================
  -- Selbst-korrigierend: GETAGGTE Entnahme senkt Saldo UND reserviert gleich -> kein Breach; eine UN-getaggte
  --   Belastung danach erzeugt ihn. (Konto A wiederverwendet: +500 reserviert, +1000 frei = Saldo 1500.)
  --   getaggte Entnahme -1000 (Ziel A): Saldo 500, reserviert -500? NEIN -> eigenes Konto, sauber aufgebaut.
  -- ===================================================================================
  -- frisches Konto: Reserve +400 (getaggt), getaggte Entnahme -150 (getaggt, selbes Ziel) -> Saldo 250, reserviert 250 -> KEIN Breach (gleich).
  SELECT finance.fn_create_account('{"name":"__rb_sc__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_a := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gSC__', 5000, current_date + 365, 'active') RETURNING id INTO v_gA;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_a,  400, current_date - 30, 'transfer', v_gA, gen_random_uuid()),   -- Reserve-Zufluss (getaggt)
    (v_a, -150, current_date - 20, 'transfer', v_gA, gen_random_uuid());   -- getaggte Entnahme (senkt Saldo UND reserviert)
  SELECT balance, reserved, breach INTO v_bal, v_rsv, v_breach FROM finance.account_reserve_status WHERE account_id = v_a;
  IF v_bal IS DISTINCT FROM 250 OR v_rsv IS DISTINCT FROM 250 OR v_breach IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [SC getaggt]: balance=% reserved=% breach=% (getaggte Entnahme ist neutral -> kein Breach)', v_bal, v_rsv, v_breach; END IF;
  -- jetzt eine UN-getaggte Belastung -50 -> Saldo 200 < reserviert 250 -> Breach 50
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id) VALUES (v_a, -50, current_date - 5, 'other', NULL);
  SELECT shortfall, breach INTO v_short, v_breach FROM finance.account_reserve_status WHERE account_id = v_a;
  IF v_breach IS DISTINCT FROM true OR v_short IS DISTINCT FROM 50 THEN
    RAISE EXCEPTION 'FAIL [SC un-getaggt]: breach=% shortfall=% (un-getaggte Ausgabe -50 -> Breach 50)', v_breach, v_short; END IF;
  RAISE NOTICE 'PASS [Selbst-korrigierend: getaggte Entnahme neutral; erst un-getaggte Belastung erzeugt Breach]';

  -- ===================================================================================
  -- AKTIVE Ziele only: Reserve +500 (getaggt), un-getaggte -400 -> Saldo 100 < 500 -> Breach. Ziel completed ->
  --   reserviert 0 -> KEIN Breach mehr (das Ziel gibt seine Reserve frei).
  -- ===================================================================================
  SELECT finance.fn_create_account('{"name":"__rb_comp__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_c := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gComp__', 500, current_date + 365, 'active') RETURNING id INTO v_gComp;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_c,  500, current_date - 30, 'transfer', v_gComp, gen_random_uuid()),
    (v_c, -400, current_date - 10, 'other',    NULL, NULL);
  IF (SELECT breach FROM finance.account_reserve_status WHERE account_id = v_c) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [Active pre]: aktives Ziel -> Breach erwartet'; END IF;
  UPDATE finance.savings_goals SET status = 'completed' WHERE id = v_gComp;
  SELECT reserved, breach INTO v_rsv, v_breach FROM finance.account_reserve_status WHERE account_id = v_c;
  IF v_rsv IS DISTINCT FROM 0 OR v_breach IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [Active post]: completed-Ziel zaehlt nicht -> reserved=% breach=% (erwartet 0/false)', v_rsv, v_breach; END IF;
  RAISE NOTICE 'PASS [Aktive-Ziele-only: completed-Ziel gibt Reserve frei -> Konto ent-breacht]';

  -- ===================================================================================
  -- Multi-Waehrung native: USD-Konto, Reserve +500 USD (getaggt) + un-getaggt -300 USD -> Saldo 200, reserviert
  --   500, Fehlbetrag 300 (alles USD, KEIN FX). note traegt die native Waehrung USD.
  -- ===================================================================================
  PERFORM finance.fn_ensure_currency('USD');   -- USD in finance.currencies registrieren (FK accounts.currency)
  SELECT finance.fn_create_account('{"name":"__rb_usd__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_usd := (v_res->>'account_id')::int;
  UPDATE finance.accounts SET currency = 'USD' WHERE id = v_usd;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gUSD__', 5000, current_date + 365, 'active') RETURNING id INTO v_gUSD;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id) VALUES
    (v_usd,  500, current_date - 30, 'transfer', v_gUSD, gen_random_uuid()),
    (v_usd, -300, current_date - 10, 'other',    NULL, NULL);
  SELECT shortfall, breach, currency INTO v_short, v_breach, v_cur FROM finance.account_reserve_status WHERE account_id = v_usd;
  IF v_breach IS DISTINCT FROM true OR v_short IS DISTINCT FROM 300 OR v_cur IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [USD view]: shortfall=% breach=% currency=% (erwartet 300/true/USD)', v_short, v_breach, v_cur; END IF;
  v_br := finance.fn_reserve_breach(v_usd);
  IF v_br IS NULL OR (v_br->>'note') NOT LIKE '%USD%' OR (v_br->>'note') LIKE '%EUR%' THEN
    RAISE EXCEPTION 'FAIL [USD note]: note muss native USD nennen (nicht EUR): %', v_br->>'note'; END IF;
  RAISE NOTICE 'PASS [Multi-Waehrung: USD-Konto Breach 300 USD, note native USD (kein FX/EUR)]';

  -- ===================================================================================
  -- WP-5a: fn_reserve_breach auf ein DEPOT-Konto -> NULL. Der fruehere Depot-Zweig war write-time unerreichbarer
  --   toter Code (kein Aufrufer uebergibt je ein Depot); die Cash-Branch matcht keine Depots -> NULL, auch wenn
  --   depot_reserve_status breacht (der Depot-Deckungs-Dialog laeuft ueber fn_advisor_review, nicht hier).
  -- ===================================================================================
  DECLARE v_set INT; v_dep INT; v_gD INT; BEGIN
    SELECT finance.fn_create_account('{"name":"__rb_set__","account_type":"cash"}'::jsonb) INTO v_res; v_set := (v_res->>'account_id')::int;
    SELECT finance.fn_create_account(jsonb_build_object('name','__rb_dep__','account_type','stocks_depot','settlement_id',v_set)) INTO v_res; v_dep := (v_res->>'account_id')::int;
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rb_gD__', 5000, current_date + 365, 'active') RETURNING id INTO v_gD;
    INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
      VALUES (v_gD, v_dep, 1000, 'manual');   -- reserved 1000, kein Marktwert -> depot_reserve_status.breach
    IF (SELECT breach FROM finance.depot_reserve_status WHERE account_id = v_dep) IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'SETUP FAIL [WP-5a]: depot_reserve_status.breach erwartet true'; END IF;
    IF finance.fn_reserve_breach(v_dep) IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [WP-5a]: fn_reserve_breach(Depot) muss NULL sein (toter Depot-Zweig entfernt), got %', finance.fn_reserve_breach(v_dep); END IF;
    RAISE NOTICE 'PASS [WP-5a: fn_reserve_breach(Depot) -> NULL (entfernter toter Zweig), Cash-Branch unberuehrt]';
  END;

  RAISE NOTICE 'ALL PASS test_fn_reserve_breach';
END $$;

ROLLBACK;
