-- tests/db/finance/test_fn_close_savings_goal.sql
-- Testet fn_close_savings_goal: Hard-DELETE (+ Reserve-Journal CASCADE), Soft-Close, not-found
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_g_a    INT; v_rp_a INT;
  v_g_b    INT; v_rp_b INT;
  v_g_c    INT; v_rp_c INT;
  v_cnt    INT; v_status TEXT; v_valid_to DATE; v_rp_status TEXT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_csg_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- Goal A: RP + Depot-Reserve-Journal-Zeile, KEINE getaggte Buchung -> Hard-DELETE (Journal muss CASCADE mitgehen)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_a__','target_amount',5000,'target_date',(CURRENT_DATE + 365)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_a := (v_res->>'goal_id')::int; v_rp_a := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_g_a, v_acct, 500, 'manual');

  -- Goal B: RP + eine Buchung -> Soft-Close
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_b__','target_amount',8000,'target_date',(CURRENT_DATE + 365)::text,
    'monthly_savings_rate',150,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_b := (v_res->>'goal_id')::int; v_rp_b := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -150, CURRENT_DATE - 30, 'other', v_rp_b, 'Test-Sparrate');

  -- Goal C (WS-A Regressionsfall): RP existiert, aber KEINE Rate-Tx — nur eine getaggte manuelle
  -- Reserve-Bewegung (savings_goal_id gesetzt, recurring_payment_id NULL). Unter dem ALTEN Zaehler (nur
  -- recurring_payment_id) waere das 0 -> faelschlich Hard-DELETE; der WS-A-Zaehler sieht den Tag -> Soft-Close.
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_c__','target_amount',3000,'target_date',(CURRENT_DATE + 365)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_c := (v_res->>'goal_id')::int; v_rp_c := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id, description)
  VALUES (v_acct, 500, CURRENT_DATE - 5, 'transfer', v_g_c, gen_random_uuid(), 'Manuelle Einzahlung (kein Rate-Tx)');

  -- TEST 1: Hard-DELETE + Reserve-Journal CASCADE
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_a__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL close_savings_goal [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.savings_goals WHERE id = v_g_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_savings_goal [goal A noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_g_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_savings_goal [Reserve-Journal nicht kaskadiert]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_savings_goal [rp A noch da]'; END IF;
  RAISE NOTICE 'PASS close_savings_goal [Hard-DELETE: Goal + Reserve-Journal (CASCADE) + RP entfernt]';

  -- TEST 2: Soft-Close
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_b__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close_savings_goal [soft-close]: %', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_g_b;
  IF v_status IS DISTINCT FROM 'cancelled' THEN RAISE EXCEPTION 'FAIL close_savings_goal [soft-close status]: %', v_status; END IF;
  SELECT status::text, valid_to INTO v_rp_status, v_valid_to FROM finance.recurring_payments WHERE id = v_rp_b;
  IF v_rp_status IS DISTINCT FROM 'paused' OR v_valid_to IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL close_savings_goal [soft-close rp]: status=% valid_to=%', v_rp_status, v_valid_to; END IF;
  RAISE NOTICE 'PASS close_savings_goal [Soft-Close: cancelled + RP beendet]';

  -- TEST 2b (WS-A): Ziel mit NUR getaggter manueller Tx (kein Rate-Tx) -> Soft-Close (nicht Hard-DELETE)
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_c__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close_savings_goal [tagged soft-close]: erwartet action=closed, got % (getaggte Tx uebersehen?)', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_g_c;
  IF v_status IS DISTINCT FROM 'cancelled' THEN RAISE EXCEPTION 'FAIL close_savings_goal [tagged status]: %', v_status; END IF;
  RAISE NOTICE 'PASS close_savings_goal [getaggte Einmal-Tx ohne Rate-Tx -> Soft-Close (WS-A Regressionsfall)]';

  -- TEST 3: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL close_savings_goal [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS close_savings_goal [not-found -> ok:false]';
END $$;

-- ============================================================
-- WS-B Stufe 3 (Phase S): Lebenszyklus "erreicht != ausgegeben" — drei distinkte Ereignisse.
--   (4) ERFUELLT -> outcome='completed' nur wenn Reserve ~0 (current_amount); sonst {ok:false} (kein Auto-
--       Freigeben). force=true ueberstimmt ("trotz Restbetrag schliessen").
--   (5) ABGEBROCHEN -> outcome='cancelled' Hard-DELETE (tx_count=0): Journal CASCADE weg, savings_plan
--       entkoppelt (savings_goal_id SET NULL), der Plan selbst BLEIBT (RESTRICT).
--   (6) ABGEBROCHEN soft (tx_count>0): status='cancelled' + Cash-Tag savings_goal_id SET NULL (Zuordnung frei,
--       Buchung als Historie bleibt) -> die Euros sind reassignbar.
-- ============================================================
DO $$
DECLARE
  v_res JSONB; v_acct INT;
  v_g_d INT; v_g_e INT; v_g_f INT; v_rp_f INT; v_plan_f INT; v_rp_pf INT; v_depot INT;
  v_g_g INT; v_tx_g INT;
  v_status TEXT; v_cnt INT; v_goal_id_after INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_csg2_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__test_csg2_depot__','stocks_depot','EUR','active', v_acct) RETURNING id INTO v_depot;

  -- (4) completed-Gate: Ziel D mit getaggter Cash-Reserve (current_amount=2000) -> completed ohne force = {ok:false}
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_d__','target_amount',2000,'target_date',(CURRENT_DATE + 200)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_d := (v_res->>'goal_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id, description)
  VALUES (v_acct, 2000, CURRENT_DATE - 10, 'transfer', v_g_d, gen_random_uuid(), 'Reserve-Einzahlung');

  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_d__","outcome":"completed"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL close [4]: completed bei Reserve 2000 muss {ok:false} sein (got %)', v_res; END IF;
  RAISE NOTICE 'PASS close [4: completed mit Restreserve -> {ok:false}, kein Auto-Freigeben]';

  -- jetzt Reserve entnehmen -> current_amount ~0 -> completed erlaubt (Soft-Close, da tx vorhanden)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id, description)
  VALUES (v_acct, -2000, CURRENT_DATE - 1, 'transfer', v_g_d, gen_random_uuid(), 'Auto gekauft');
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_d__","outcome":"completed"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close [4]: completed bei Reserve ~0 muss action=closed sein (got %)', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_g_d;
  IF v_status IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL close [4]: Status erwartet completed, got %', v_status; END IF;
  RAISE NOTICE 'PASS close [4: Reserve entnommen -> completed (status=completed)]';

  -- (4b) force ueberstimmt den Reserve-Gate: Ziel E mit Restreserve + force=true -> closed completed
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_e__','target_amount',1000,'target_date',(CURRENT_DATE + 200)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_e := (v_res->>'goal_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id, description)
  VALUES (v_acct, 500, CURRENT_DATE - 5, 'transfer', v_g_e, gen_random_uuid(), 'Restreserve');
  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_e__","outcome":"completed","force":true}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close [4b]: completed force=true muss trotz Restreserve schliessen (got %)', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_g_e;
  IF v_status IS DISTINCT FROM 'completed' THEN RAISE EXCEPTION 'FAIL close [4b]: Status erwartet completed, got %', v_status; END IF;
  RAISE NOTICE 'PASS close [4b: force=true schliesst trotz Restreserve als completed]';

  -- (5) cancelled Hard-DELETE (tx_count=0): Ziel F mit verknuepftem Sparplan + Journal, KEINE tx.
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_f__','target_amount',3000,'target_date',(CURRENT_DATE + 200)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_f := (v_res->>'goal_id')::int; v_rp_f := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__test_csg_f_rp__', v_acct, -50, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp_pf;
  INSERT INTO finance.savings_plans (name, depot_id, isin, symbol, security_name, recurring_payment_id, savings_goal_id, status)
  VALUES ('__test_csg_f_plan__', v_depot, 'IE00BK5BQT80','VWCE','ETF', v_rp_pf, v_g_f, 'active') RETURNING id INTO v_plan_f;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_g_f, v_depot, 900, 'manual');

  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_f__","outcome":"cancelled"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL close [5]: cancelled ohne tx muss action=deleted sein (got %)', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.savings_goals WHERE id = v_g_f;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close [5]: Ziel F noch da'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_g_f;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close [5]: Journal nicht kaskadiert (weg)'; END IF;
  SELECT savings_goal_id INTO v_goal_id_after FROM finance.savings_plans WHERE id = v_plan_f;
  IF v_goal_id_after IS NOT NULL THEN RAISE EXCEPTION 'FAIL close [5]: Sparplan nicht entkoppelt (savings_goal_id=%)', v_goal_id_after; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.savings_plans WHERE id = v_plan_f;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL close [5]: Sparplan selbst geloescht (Bestand muss bleiben, RESTRICT)'; END IF;
  RAISE NOTICE 'PASS close [5: cancelled Hard-DELETE -> Journal weg (CASCADE), Sparplan entkoppelt + ueberlebt]';

  -- (6) cancelled soft (tx_count>0): Ziel G mit Cash-Tag -> status=cancelled + Tag SET NULL (Historie bleibt)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_csg_g__','target_amount',5000,'target_date',(CURRENT_DATE + 200)::text,
    'monthly_savings_rate',100,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_g_g := (v_res->>'goal_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id, description)
  VALUES (v_acct, 800, CURRENT_DATE - 5, 'transfer', v_g_g, gen_random_uuid(), 'Reserve') RETURNING id INTO v_tx_g;

  SELECT finance.fn_close_savings_goal('{"savings_goal_name":"__test_csg_g__","outcome":"cancelled"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close [6]: cancelled mit tx muss action=closed sein (got %)', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_g_g;
  IF v_status IS DISTINCT FROM 'cancelled' THEN RAISE EXCEPTION 'FAIL close [6]: Status erwartet cancelled, got %', v_status; END IF;
  -- Buchung bleibt (Historie), aber savings_goal_id ist frei (NULL)
  SELECT savings_goal_id INTO v_goal_id_after FROM finance.transactions WHERE id = v_tx_g;
  IF v_goal_id_after IS NOT NULL THEN RAISE EXCEPTION 'FAIL close [6]: Cash-Tag nicht freigegeben (savings_goal_id=%)', v_goal_id_after; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.transactions WHERE id = v_tx_g;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL close [6]: Buchung geloescht (Historie muss bleiben)'; END IF;
  RAISE NOTICE 'PASS close [6: cancelled soft -> status=cancelled + Cash-Tag SET NULL (reassignbar, Historie bleibt)]';
END $$;

-- (7) Ziel nur mit Zuordnung (Journal, keine Buchung; Sparziel-Zweckbindung 2026-10-27): completed mit force schliesst
--     WEICH (Erfuellungs-Historie bleibt sichtbar); cancelled bleibt Hard-DELETE (kein Geld floss, Journal CASCADE).
--     Beide Zuordnungen zaehlen danach nicht mehr gegen den Saldo.
DO $$
DECLARE v_p2p int; v_ga int; v_gb int; v_r jsonb; v_res numeric;
BEGIN
  v_p2p := (finance.fn_create_account('{"name":"__cl7_p2p__","account_type":"p2p","opening_balance":5000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__cl7 a__', 2000, current_date + 100, 'active') RETURNING id INTO v_ga;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__cl7 b__', 1000, current_date + 100, 'active') RETURNING id INTO v_gb;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_ga, 'account_id', v_p2p, 'amount', 2000));
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_gb, 'account_id', v_p2p, 'amount', 1000));

  v_r := finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name', '__cl7 a__', 'outcome', 'completed', 'force', true));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'action' IS DISTINCT FROM 'closed'
     OR (SELECT status::text FROM finance.savings_goals WHERE id = v_ga) IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'FAIL close [7 completed weich]: %', v_r; END IF;
  v_r := finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name', '__cl7 b__', 'outcome', 'cancelled'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'action' IS DISTINCT FROM 'deleted'
     OR EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_gb) THEN
    RAISE EXCEPTION 'FAIL close [7 cancelled hart]: %', v_r; END IF;
  SELECT reserved INTO v_res FROM finance.account_reserve_status WHERE account_id = v_p2p;
  IF v_res IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL close [7 Zuordnung frei]: reserved %', v_res; END IF;
  RAISE NOTICE 'PASS close [7: nur Zuordnung -> erfuellt weich, abgebrochen hart; Saldo wieder frei]';
END $$;

ROLLBACK;
