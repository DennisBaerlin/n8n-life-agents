-- tests/db/finance/test_fn_create_savings_goal.sql
-- Testet fn_create_savings_goal: Ziel + recurring_payment + FK-Link.
-- Rate/Zieldatum rechnet die DB (fn_savings_rate_schedule), NICHT das LLM:
-- target_amount + GENAU EINES von {target_date, monthly_savings_rate}.
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_acct_id  INT;
  v_pot_id   INT;   -- Audit Paket 3: Sparkonto (Reserve-Topf) ist Pflicht
  v_goal_id  INT;
  v_rp_id    INT;
  v_dom      SMALLINT := 15;
  v_rp_amount  NUMERIC;
  v_rp_account INT;
  v_rp_unit    TEXT;
  v_linked_rp  INT;
  v_goal_date  DATE;
BEGIN

  -- Setup: Abbuchungskonto
  SELECT finance.fn_create_account(
    '{"name":"__test_saving_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account(
    '{"name":"__test_saving_pot__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_pot_id := (v_result->>'account_id')::int;

  -- TEST 1: ZIEL-getrieben — 12000 EUR, first 2027-01-01 .. target 2028-01-01 -> 12 Monate -> Rate 1000 (DB-berechnet)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name',                '__test_saving_goal__',
    'goal_type',           'vacation',
    'target_amount',       12000,
    'target_date',         '2028-01-01',
    'account_id',          v_acct_id,
    'reserve_account_id',  v_pot_id,
    'schedule_day_of_month', v_dom,
    'first_payment_date',  '2027-01-01',
    'notes',               'Urlaub 2027'
  )) INTO v_result;

  IF NOT (v_result ? 'goal_id') OR NOT (v_result ? 'recurring_payment_id') THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal: fehlende IDs im Result, got %', v_result;
  END IF;
  v_goal_id := (v_result->>'goal_id')::int;
  v_rp_id   := (v_result->>'recurring_payment_id')::int;

  -- Assert: Post-State — Rate DB-berechnet (1000), target_date durchgereicht
  IF (v_result->>'monthly_rate')::numeric IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [return monthly_rate]: erwartet 1000, got %', v_result->>'monthly_rate';
  END IF;
  IF (v_result->>'target_date')::date IS DISTINCT FROM '2028-01-01'::date THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [return target_date]: erwartet 2028-01-01, got %', v_result->>'target_date';
  END IF;
  -- Post-State-Vertrag: kein Echo der Eingabe reserve_account_id
  IF v_result ? 'reserve_account_id' THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [reserve echo]: Input-Echo im Return, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [target-driven]: rate=%, goal_id=%, rp_id=%', v_result->>'monthly_rate', v_goal_id, v_rp_id;

  -- Assert: Sparziel korrekt gespeichert (target_date = aufgeloest)
  SELECT target_date INTO v_goal_date FROM finance.savings_goals
  WHERE id = v_goal_id AND target_amount = 12000 AND status = 'active' AND recurring_payment_id = v_rp_id;
  IF v_goal_date IS DISTINCT FROM '2028-01-01'::date THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal: Sparziel nicht korrekt in DB (target_date=%)', v_goal_date;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [Sparziel in DB]';

  -- Assert: recurring_payment korrekt (Rate = -1000, monatlich, richtiges Konto)
  SELECT amount, account_id, schedule_unit::text
  INTO v_rp_amount, v_rp_account, v_rp_unit
  FROM finance.recurring_payments WHERE id = v_rp_id;

  IF v_rp_amount IS DISTINCT FROM -1000 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rp_amount]: erwartet -1000, got %', v_rp_amount;
  END IF;
  IF v_rp_account IS DISTINCT FROM v_acct_id THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rp_account]: erwartet %, got %', v_acct_id, v_rp_account;
  END IF;
  IF v_rp_unit IS DISTINCT FROM 'month' THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rp_unit]: erwartet month, got %', v_rp_unit;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [recurring_payment: amount=%, account=%, unit=%]',
    v_rp_amount, v_rp_account, v_rp_unit;

  -- Assert: FK-Link goal -> rp gesetzt
  SELECT recurring_payment_id INTO v_linked_rp
  FROM finance.savings_goals WHERE id = v_goal_id;
  IF v_linked_rp IS DISTINCT FROM v_rp_id THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [FK-Link]: erwartet %, got %', v_rp_id, v_linked_rp;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [FK-Link gesetzt]';

  -- Assert: schedule_day_of_month korrekt
  IF NOT EXISTS (
    SELECT 1 FROM finance.recurring_payments
    WHERE id = v_rp_id AND schedule_day_of_month = v_dom
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal: schedule_day_of_month % nicht gespeichert', v_dom;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [schedule_day_of_month=%]', v_dom;

  -- TEST 2: RATEN-getrieben — 50000 EUR bei 200/Monat (kein target_date) -> DB berechnet target_date (first + 250 Monate)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_ratedriven__', 'target_amount', 50000,
    'monthly_savings_rate', 200,
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rate-driven]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'monthly_rate')::numeric IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rate-driven rate]: erwartet 200, got %', v_result->>'monthly_rate';
  END IF;
  IF (v_result->>'target_date')::date IS DISTINCT FROM ('2027-01-01'::date + INTERVAL '250 months')::date THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rate-driven date]: erwartet %, got %',
      ('2027-01-01'::date + INTERVAL '250 months')::date, v_result->>'target_date';
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [rate-driven]: date=%', v_result->>'target_date';

  -- TEST 3: weder Datum noch Rate -> {ok:false} (korrigierbar, kein RAISE)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_neither__', 'target_amount', 5000,
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 15, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [neither]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [neither date nor rate -> ok:false]';

  -- TEST 4: Rate <= 0 (raten-getrieben, kein Datum) -> {ok:false}
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_bad_rate__', 'target_amount', 5000,
    'monthly_savings_rate', 0,
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 15, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [rate<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [rate<=0 -> ok:false]';

  -- TEST 5: Zielbetrag <= 0 -> {ok:false}
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_bad_target__', 'target_amount', 0,
    'target_date', '2028-01-01',
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 15, 'first_payment_date', '2027-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [target<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [target<=0 -> ok:false]';

  -- TEST 6 (WS-4): beneficiary_person_id (beguenstigte Person, z. B. Kind-Sparziel) gesetzt + NULL=Haushalt.
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_sg_kid', 'Test Kind', 'child') ON CONFLICT (person_id) DO NOTHING;
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_kid__', 'target_amount', 6000, 'target_date', '2030-01-01',
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01',
    'beneficiary_person_id', '__test_sg_kid'
  )) INTO v_result;
  v_goal_id := (v_result->>'goal_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal_id AND beneficiary_person_id = '__test_sg_kid') THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [6]: beneficiary_person_id nicht gesetzt (id=%)', v_goal_id;
  END IF;
  -- Das ZIEL aus TEST 1 (ohne beneficiary) -> NULL = Haushalt.
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE name = '__test_saving_goal__' AND beneficiary_person_id IS NULL) THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [6b]: ohne beneficiary muss NULL=Haushalt sein';
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [6 beneficiary_person_id gesetzt + NULL=Haushalt]';

  -- TEST 6c: ohne genannte Person erbt das Ziel den Inhaber des Spartopfs (Topf einer Person, fn_default_beneficiary)
  DECLARE v_pot_p INT; BEGIN
    INSERT INTO agent.persons (person_id, full_name, role)
    VALUES ('__test_sg_owner', 'Test Inhaber', 'owner') ON CONFLICT (person_id) DO NOTHING;
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('__test_sg_pot_owned__', 'cash', 'EUR', 'active', '__test_sg_owner') RETURNING id INTO v_pot_p;
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_saving_goal_owned__', 'target_amount', 6000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'reserve_account_id', v_pot_p, 'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01'
    )) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true
       OR (SELECT beneficiary_person_id FROM finance.savings_goals WHERE id = (v_result->>'goal_id')::int) IS DISTINCT FROM '__test_sg_owner'
       OR v_result->>'beneficiary_person_id' IS DISTINCT FROM '__test_sg_owner'
       OR v_result->'effective'->>'beneficiary_person_id' IS DISTINCT FROM '__test_sg_owner' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_goal [6c Topf-Inhaber]: %', v_result; END IF;
    RAISE NOTICE 'PASS fn_create_savings_goal [6c ohne Person -> Inhaber des Spartopfs]';
  END;

  -- TEST 7 (WS-C1): priority gesetzt -> persistiert; ohne priority -> NULL (unpriorisiert).
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_saving_goal_prio__', 'target_amount', 6000, 'target_date', '2030-01-01',
    'account_id', v_acct_id, 'reserve_account_id', v_pot_id,'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01',
    'priority', 1
  )) INTO v_result;
  v_goal_id := (v_result->>'goal_id')::int;
  IF (SELECT priority FROM finance.savings_goals WHERE id = v_goal_id) IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [7 priority]: erwartet 1, got %', (SELECT priority FROM finance.savings_goals WHERE id = v_goal_id); END IF;
  -- TEST 1-Ziel ohne priority -> NULL (unpriorisiert)
  IF (SELECT priority FROM finance.savings_goals WHERE name = '__test_saving_goal__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_goal [7b priority]: ohne Eingabe muss priority NULL sein'; END IF;
  RAISE NOTICE 'PASS fn_create_savings_goal [7 priority=1 gesetzt + ohne Eingabe NULL]';

  -- TEST 9 (Audit Paket 3): ein Sparziel braucht ein Sparkonto -> ohne/ungeeignetes Konto {ok:false}, KEIN Write.
  DECLARE v_cnt0 int; v_depot int; v_closed int; v_loan int; BEGIN
    SELECT count(*) INTO v_cnt0 FROM finance.savings_goals;
    -- (9a) ohne reserve_account_id
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_sg_no_pot__', 'target_amount', 3000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR COALESCE(v_result->>'reason','') NOT ILIKE '%savings account%' THEN
      RAISE EXCEPTION 'FAIL [9a]: ohne Sparkonto erwartet ok:false mit Grund, got %', v_result; END IF;
    -- (9b) Depot als Topf (Saldo strukturell 0) -> abgelehnt
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__test_sg_depot__','stocks_depot','EUR','active', v_acct_id) RETURNING id INTO v_depot;
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_sg_depot_pot__', 'target_amount', 3000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'reserve_account_id', v_depot,
      'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [9b]: Depot als Sparkonto erwartet ok:false, got %', v_result; END IF;
    -- (9c) geschlossenes Konto als Topf -> abgelehnt
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__test_sg_closed__','cash','EUR','closed') RETURNING id INTO v_closed;
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_sg_closed_pot__', 'target_amount', 3000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'reserve_account_id', v_closed,
      'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [9c]: geschlossenes Sparkonto erwartet ok:false, got %', v_result; END IF;
    -- (9d) Topf = Abbuchungskonto -> abgelehnt (bestehende Regel)
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_sg_same__', 'target_amount', 3000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'reserve_account_id', v_acct_id,
      'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [9d]: Topf = Abbuchungskonto erwartet ok:false, got %', v_result; END IF;
    -- (9e) Festgeld als Topf ist erlaubt
    INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__test_sg_fd__','fixed_deposit','EUR','active','2030-12-31') RETURNING id INTO v_loan;
    SELECT finance.fn_create_savings_goal(jsonb_build_object(
      'name', '__test_sg_fd_pot__', 'target_amount', 3000, 'target_date', '2030-01-01',
      'account_id', v_acct_id, 'reserve_account_id', v_loan,
      'schedule_day_of_month', 1, 'first_payment_date', '2027-01-01')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [9e]: Festgeld als Sparkonto erwartet ok:true, got %', v_result; END IF;
    IF (SELECT count(*) FROM finance.savings_goals) <> v_cnt0 + 1 THEN
      RAISE EXCEPTION 'FAIL [9]: abgelehnte Anlagen duerfen nichts schreiben (Delta %)', (SELECT count(*) FROM finance.savings_goals) - v_cnt0; END IF;
    -- Post-State: die neue Rate ist ein Transfer in den Topf (Fortschritt messbar)
    IF NOT EXISTS (SELECT 1 FROM finance.savings_goal_progress WHERE id = (v_result->>'goal_id')::int AND progress_measurable) THEN
      RAISE EXCEPTION 'FAIL [9e]: neues Ziel mit Topf muss progress_measurable sein'; END IF;
    RAISE NOTICE 'PASS fn_create_savings_goal [9 Sparkonto Pflicht: fehlt/Depot/geschlossen/gleich -> ok:false; Festgeld ok]';
  END;

END $$;

-- TEST 8 (Phase L WS-4): Ueber-Spar-Sofort-Hinweis (Event-Fold). Die Fold-fn liest monthly_cashflow_summary
-- (GLOBALE Single-Row-View; Audit Paket 3: monthly_free>=0 + monthly_account_change<0) -> SAVEPOINT + bestehende rp
-- der TESTs 1-7 neutralisieren, kontrollierten Cashflow setzen, danach ROLLBACK TO SAVEPOINT. (8a) Reserve-Rate
-- kippt die Kontoveraenderung <0 -> savings_squeeze-Note im {ok:true}-Return. (8b) gesunde Rate -> KEINE Note.
SAVEPOINT sg_fold;
UPDATE finance.recurring_payments SET status='paused';
DO $$
DECLARE
  v_result jsonb; v_fund int; v_res int; v_rp8a int;
BEGIN
  SELECT finance.fn_create_account('{"name":"__pl_fund__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_result;
  v_fund := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__pl_resv__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_result;
  v_res := (v_result->>'account_id')::int;
  -- kleines Einkommen +1000/Monat (aktiv, non-transfer)
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__pl_fold_inc__', v_fund, 1000, 'month', current_date, current_date);

  -- (8a) Reserve-Topf + Rate 1500/Monat (Transfer) -> monthly_net +1000, liquidity_net -500 -> Fold
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__pl_fold_goal__','target_amount', 90000, 'monthly_savings_rate', 1500,
    'account_id', v_fund, 'reserve_account_id', v_res,
    'schedule_day_of_month', 1, 'first_payment_date', current_date::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [8a setup]: Ziel-Anlage scheiterte: %', v_result; END IF;
  IF NOT (v_result ? 'savings_squeeze') OR COALESCE(v_result->'savings_squeeze'->>'note','') = '' THEN
    RAISE EXCEPTION 'FAIL [8a]: kein savings_squeeze-Fold mit note bei Kontoveraenderung <0, got %', v_result; END IF;
  IF (v_result->'savings_squeeze'->>'account_change')::numeric IS DISTINCT FROM -500.00 THEN
    RAISE EXCEPTION 'FAIL [8a]: account_change -500 erwartet (frei 1000 - Sparen 1500), got %', v_result->'savings_squeeze'; END IF;
  RAISE NOTICE 'PASS [8a WS-4: Reserve-Rate kippt die Kontoveraenderung <0 -> savings_squeeze-Fold im Return]';

  -- 8a-Rate raus, damit 8b sauber misst
  v_rp8a := (v_result->>'recurring_payment_id')::int;
  UPDATE finance.recurring_payments SET status='paused' WHERE id = v_rp8a;

  -- (8b) gesunde Rate 200/Monat -> monthly_net +1000, liquidity_net +800 -> KEINE Note
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__pl_fold_goal_ok__','target_amount', 90000, 'monthly_savings_rate', 200,
    'account_id', v_fund, 'reserve_account_id', v_res,
    'schedule_day_of_month', 1, 'first_payment_date', current_date::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [8b setup]: Ziel-Anlage scheiterte: %', v_result; END IF;
  IF v_result ? 'savings_squeeze' THEN
    RAISE EXCEPTION 'FAIL [8b]: savings_squeeze-Fold trotz gesundem liquidity_net (+800), got %', v_result; END IF;
  RAISE NOTICE 'PASS [8b WS-4: gesunde Rate -> kein Fold]';

  -- (8c, Code-Review) schon bestehendes Pflicht-Defizit: Ausgabe 1200 > Einnahmen 1000 -> neues Ziel warnt trotzdem
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = (v_result->>'recurring_payment_id')::int;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__pl_fold_rent__', v_fund, -1200, 'month', current_date, current_date);
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');   -- Latch aus 8a zuruecksetzen (sonst 24h-TTL)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__pl_fold_goal_deficit__','target_amount', 9000, 'monthly_savings_rate', 100,
    'account_id', v_fund, 'reserve_account_id', v_res,
    'schedule_day_of_month', 1, 'first_payment_date', current_date::text
  )) INTO v_result;
  IF COALESCE(v_result->'savings_squeeze'->>'note','') NOT ILIKE '%already exceed%' THEN
    RAISE EXCEPTION 'FAIL [8c]: im Pflicht-Defizit muss die Anlage warnen (already exceed), got %', v_result; END IF;
  RAISE NOTICE 'PASS [8c: Sparziel im bestehenden Defizit -> Hinweis]';
END $$;
ROLLBACK TO SAVEPOINT sg_fold;

-- Sparziel-Zweckbindung 2026-10-27 (Anlegen ohne Rate / mit Startbestand / mit Sparplan):
--  (C1) Owner-Fall: Geld liegt schon auf einem P2P-Konto, already_saved = Ziel, KEIN Abbuchungskonto -> ok, keine rp,
--       monthly_rate 0, current_amount = Ziel, 100 %, eine manual-Journal-Zeile, Karten-Hinweis "gedeckt"
--  (C2) teilweise gedeckt: Rate auf dem Rest, rp in den Topf, Startbestand im Journal
--  (C3) keine Quelle (kein Startbestand, keine Rate/kein Abbuchungskonto, kein Sparplan) -> ok:false, kein Write
--  (C4) Startbestand groesser als der freie Saldo -> ok:false insufficient_free_balance, kein Write
--  (C5) Depot als Topf, voll gedeckt durch Depot-Zuordnung (EUR) -> ok, keine rp
--  (C6) Depot als Topf, nicht gedeckt, ohne Sparplan -> ok:false
--  (C7) Sparplan bei Anlage verknuepfen: keine eigene rp, required_monthly_rate + plan_monthly_amount, Plan gebunden
--  (C8) Sparplan, der schon an ein anderes Ziel gebunden ist -> ok:false
DO $$
DECLARE
  v_giro int; v_p2p int; v_p2p2 int; v_settle int; v_depot int; v_r jsonb; v_goal int; v_cnt int; v_cnt0 int; v_plan int;
  v_exp numeric;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__sgc_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_p2p  := (finance.fn_create_account('{"name":"__sgc_p2p__","account_type":"p2p","opening_balance":4000}'::jsonb)->>'account_id')::int;
  v_p2p2 := (finance.fn_create_account('{"name":"__sgc_p2p2__","account_type":"p2p","opening_balance":1000}'::jsonb)->>'account_id')::int;

  -- (C1)
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Reise__','target_amount',3000,
           'target_date',(core.fn_today() + 70)::text,'reserve_account_id',v_p2p,'already_saved',3000));
  v_goal := (v_r->>'goal_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'recurring_payment_id' IS NOT NULL
     OR (v_r->>'monthly_rate')::numeric IS DISTINCT FROM 0 OR (v_r->>'current_amount')::numeric IS DISTINCT FROM 3000
     OR NOT (v_r->'card_lines' @> '[{"value":"finance.note.goal_covered"}]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL create [C1 Owner-Fall]: %', v_r; END IF;
  IF (SELECT progress_percent FROM finance.savings_goal_progress WHERE id = v_goal) IS DISTINCT FROM 100.00
     OR (SELECT recurring_payment_id FROM finance.savings_goals WHERE id = v_goal) IS NOT NULL
     OR (SELECT count(*) FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal AND kind = 'manual'
                                                                   AND account_id = v_p2p AND delta_native = 3000) <> 1 THEN
    RAISE EXCEPTION 'FAIL create [C1 Zustand]'; END IF;
  RAISE NOTICE 'PASS create [C1: Startbestand = Ziel auf P2P -> keine Rate, 100 %%, Hinweis gedeckt]';

  -- (C2) 2000 Ziel, 500 schon auf p2p2, Rest 1500 ueber eine Rate vom Giro
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Rad__','target_amount',2000,
           'target_date','2027-11-30','first_payment_date','2026-12-01','account_id',v_giro,
           'reserve_account_id',v_p2p2,'already_saved',500));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'monthly_rate')::numeric IS DISTINCT FROM 136.37
     OR (SELECT target_account_id FROM finance.recurring_payments WHERE id = (v_r->>'recurring_payment_id')::int) IS DISTINCT FROM v_p2p2
     OR (v_r->>'current_amount')::numeric IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL create [C2 teilweise]: % (Rate erwartet 1500/11 = 136.37)', v_r; END IF;
  RAISE NOTICE 'PASS create [C2: Rate auf dem Rest 1500/11, rp in den Topf]';

  SELECT count(*) INTO v_cnt0 FROM finance.savings_goals;
  -- (C3)
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Nix__','target_amount',1000,
           'target_date',(core.fn_today() + 200)::text,'reserve_account_id',v_p2p));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL create [C3 keine Quelle]: %', v_r; END IF;
  -- (C4) auf v_p2p sind 3000 von 4000 zugeordnet -> 1500 passen nicht
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Zuviel__','target_amount',1500,
           'target_date',(core.fn_today() + 200)::text,'reserve_account_id',v_p2p,'already_saved',1500));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'insufficient_free_balance'
     OR (v_r->>'free')::numeric IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL create [C4 freier Saldo]: %', v_r; END IF;
  IF (SELECT count(*) FROM finance.savings_goals) <> v_cnt0 THEN RAISE EXCEPTION 'FAIL create [C3/C4 kein Write]'; END IF;
  RAISE NOTICE 'PASS create [C3 keine Quelle, C4 mehr als frei -> ok:false ohne Write]';

  -- (C5)/(C6) Depot als Topf
  v_settle := (finance.fn_create_account('{"name":"__sgc_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__sgc_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Auto__','target_amount',4000,
           'target_date',(core.fn_today() + 900)::text,'reserve_account_id',v_depot,'already_saved',5000));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'recurring_payment_id' IS NOT NULL
     OR (SELECT currency FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = (v_r->>'goal_id')::int) IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL create [C5 Depot gedeckt]: %', v_r; END IF;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Haus__','target_amount',40000,
           'target_date',(core.fn_today() + 900)::text,'account_id',v_giro,'reserve_account_id',v_depot,'already_saved',1000));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL create [C6 Depot ohne Sparplan]: %', v_r; END IF;
  RAISE NOTICE 'PASS create [C5 Depot gedeckt ohne Rate, C6 Depot ungedeckt ohne Sparplan abgelehnt]';

  -- (C7) Sparplan 50/Monat bei Anlage verknuepfen
  v_r := finance.fn_create_savings_plan(jsonb_build_object('name','__sgc_plan__','depot_name','__sgc_depot__',
           'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',50,
           'schedule_interval',1,'schedule_unit','month','first_payment_date',core.fn_today()::text));
  v_plan := (v_r->>'savings_plan_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Rente__','target_amount',12000,
           'target_date','2036-12-31','first_payment_date','2026-12-01','reserve_account_id',v_depot,'savings_plan','__sgc_plan__'));
  v_exp := CEIL(12000.0 / 120 * 100) / 100;   -- 2026-12 .. 2036-12 = 120 Monate
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'recurring_payment_id' IS NOT NULL
     OR (v_r->>'required_monthly_rate')::numeric IS DISTINCT FROM v_exp OR (v_r->>'plan_monthly_amount')::numeric IS DISTINCT FROM 50
     OR (v_r->>'savings_plan_id')::int IS DISTINCT FROM v_plan
     OR (SELECT savings_goal_id FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM (v_r->>'goal_id')::int
     OR NOT (v_r->'card_lines' @> '[{"value":"finance.note.goal_plan_rate"}]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL create [C7 Sparplan]: % (erwartet required %)', v_r, v_exp; END IF;
  RAISE NOTICE 'PASS create [C7: Sparplan verknuepft, keine eigene Rate, Plan 50 vs noetig %]', v_exp;

  -- (C8)
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__sgc Zweit__','target_amount',5000,
           'target_date','2036-12-31','reserve_account_id',v_depot,'savings_plan','__sgc_plan__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL create [C8 Plan schon gebunden]: %', v_r; END IF;
  RAISE NOTICE 'PASS create [C8: schon gebundener Sparplan -> ok:false]';
END $$;

ROLLBACK;
