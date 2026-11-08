-- tests/db/finance/test_fn_set_savings_goal.sql
-- Testet fn_set_savings_goal: Raten-Neuberechnung (Rest/Rest-Zeit) + Recurring-Sync,
-- Status-Kaskade, Guards (target<=0, Zieldatum Vergangenheit, Ziel bereits gedeckt)
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res JSONB; v_acct INT; v_reserve INT; v_goal INT; v_rp INT;
  v_rpamt NUMERIC; v_expected NUMERIC; v_months INT; v_rpstatus TEXT; v_target INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_ssg_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_ssg_reserve__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_reserve := (v_res->>'account_id')::int;

  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_ssg_goal__','target_amount',5000,'target_date','2027-12-31',
    'monthly_savings_rate',200,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_acct,'schedule_day_of_month',1,'first_payment_date','2026-07-01')) INTO v_res;
  v_goal := (v_res->>'goal_id')::int;
  v_rp   := (v_res->>'recurring_payment_id')::int;

  -- TEST 1: Zielbetrag 5000 -> 6000 -> Rate neu = (6000 - 0 gespart) / Rest-Monate; recurring.amount = -Rate
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 6000)) INTO v_res;
  -- echte Termine: 1. des Monats ab dem naechsten 1. bis einschliesslich 31.12.2027
  SELECT count(*) INTO v_months FROM generate_series(0, 60) k
   WHERE (date_trunc('month', core.fn_today() - 1) + interval '1 month' + make_interval(months => k))::date <= DATE '2027-12-31';
  -- Audit Paket 2 (Punkt 15): auf den Cent AUFGERUNDET, damit die Raten das Ziel erreichen (vorher ROUND).
  v_expected := CEIL(6000.0 / v_months * 100) / 100;
  IF (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM v_expected THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [recompute]: rate=% (erwartet % bei % Monaten)', v_res->>'new_monthly_rate', v_expected, v_months; END IF;
  SELECT amount INTO v_rpamt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpamt IS DISTINCT FROM -v_expected THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [recurring-sync]: rp.amount=% (erwartet %)', v_rpamt, -v_expected; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Rate Rest/Rest-Zeit = %, recurring -% ]', v_expected, v_expected;

  -- TEST 2 (Audit Paket 2, Punkt 4): Status completed/cancelled ueber set umginge das Close-Gate (Reserve ~0 oder
  -- force) und gaebe Reserven still frei -> {ok:false} mit Verweis auf close_savings_goal, KEIN Write.
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'status', 'completed')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%close_savings_goal%' THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [completed-Gate]: erwartet ok=false mit Verweis, got %', v_res; END IF;
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'status', 'cancelled', 'notes', 'zz')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [cancelled-Gate]: erwartet ok=false, got %', v_res; END IF;
  SELECT status::text INTO v_rpstatus FROM finance.recurring_payments WHERE id = v_rp;
  IF v_rpstatus IS DISTINCT FROM 'active'
     OR (SELECT status::text FROM finance.savings_goals WHERE id = v_goal) IS DISTINCT FROM 'active'
     OR (SELECT notes FROM finance.savings_goals WHERE id = v_goal) IS NOT DISTINCT FROM 'zz' THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [Gate ohne Write]: rp=% goal=%', v_rpstatus,
      (SELECT status::text FROM finance.savings_goals WHERE id = v_goal); END IF;
  RAISE NOTICE 'PASS set_savings_goal [completed/cancelled -> ok:false, Verweis close_savings_goal, kein Write]';

  -- TEST 3: target_amount <= 0 -> {ok:false}
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 0)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [target<=0]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_savings_goal [target<=0 -> ok:false]';

  -- TEST 4: Zieldatum in der Vergangenheit -> {ok:false}
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_date', '2020-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [past date]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Zieldatum Vergangenheit -> ok:false]';

  -- TEST 5 (Vertragsaenderung 2026-10-27): Ziel bereits gedeckt (Reserve >= Ziel) -> ein neues Zieldatum ist erlaubt
  -- ("die Reise verschiebt sich"); die Rate wird NICHT neu gerechnet (kein Rest), covered=true meldet die Deckung.
  -- WS-A: current_amount = Reserve = markierte Bewegungen -> Deckung ueber einen markierten Reserve-Zufluss.
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
  VALUES (v_acct, 6000, CURRENT_DATE, 'transfer', v_goal, gen_random_uuid());
  SELECT amount INTO v_rpamt FROM finance.recurring_payments WHERE id = v_rp;
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_date', '2028-12-31')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'covered')::boolean IS DISTINCT FROM true
     OR v_res->>'new_monthly_rate' IS NOT NULL OR v_res->>'code' IS DISTINCT FROM 'covered_rate_running'
     OR (SELECT target_date FROM finance.savings_goals WHERE id = v_goal) IS DISTINCT FROM DATE '2028-12-31'
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM v_rpamt THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [covered: Datum verschieben]: %', v_res; END IF;
  RAISE NOTICE 'PASS set_savings_goal [gedecktes Ziel verschiebt sein Datum, Rate unveraendert, covered=true]';

  -- TEST 6 (WS-A): reserve_account_id setzen -> recurring_payments.target_account_id zieht mit (Rate wird Umbuchung)
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'reserve_account_id', v_reserve)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [reserve set]: erwartet ok=true, got %', v_res; END IF;
  SELECT target_account_id INTO v_target FROM finance.recurring_payments WHERE id = v_rp;
  IF v_target IS DISTINCT FROM v_reserve THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [reserve target]: rate.target_account_id=% (erwartet %)', v_target, v_reserve; END IF;
  -- Post-State-Vertrag: die Eingabe reserve_account_id wird nicht zurueck-ge-echot; das Handle der Rate schon.
  IF v_res ? 'reserve_account_id' THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [reserve echo]: Input-Echo im Return (=%)', v_res; END IF;
  IF (v_res->>'recurring_payment_id')::int IS DISTINCT FROM v_rp THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [rp handle]: recurring_payment_id=% (erwartet %)', v_res->>'recurring_payment_id', v_rp; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Reserve-Topf gesetzt -> rate.target_account_id]';

  -- TEST 7 (WS-A): reserve == funding (Abbuchungskonto v_acct) -> {ok:false}
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'reserve_account_id', v_acct)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [reserve==funding]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Reserve==Abbuchungskonto -> ok:false]';

  -- TEST 8 (WS-C1): priority setzen -> persistiert; leer/weggelassen -> unveraendert (COALESCE-Partial).
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'priority', 2)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL set_savings_goal [priority ok]: %', v_res; END IF;
  IF (SELECT priority FROM finance.savings_goals WHERE id = v_goal) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [priority persist]: erwartet 2, got %', (SELECT priority FROM finance.savings_goals WHERE id = v_goal); END IF;
  -- ein Update OHNE priority laesst sie unveraendert (kein stilles Null-Setzen)
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'notes', 'x')) INTO v_res;
  IF (SELECT priority FROM finance.savings_goals WHERE id = v_goal) IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [priority partial]: priority darf ohne Eingabe nicht zurueckgesetzt werden, got %', (SELECT priority FROM finance.savings_goals WHERE id = v_goal); END IF;
  RAISE NOTICE 'PASS set_savings_goal [priority gesetzt=2, ohne Eingabe unveraendert]';

  -- TEST 9 (Audit Paket 2, Punkt 1, zweiter Konsument): Ziel per close_savings_goal abgebrochen (Rate beendet,
  -- valid_to = heute), dann wieder aktiv -> Folge-rp ab heute (Reserve-Ziel geerbt), Ziel zeigt auf sie.
  DECLARE v_rp_new INT; BEGIN
    -- eine gebuchte Rate auf der (spaeter alten) rp -> Historie der Kette fuer TEST 10
    SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', '2026-07-01')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL Rate buchen: %', v_res; END IF;
    SELECT finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name','__test_ssg_goal__')) INTO v_res;
    IF v_res->>'action' IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'SETUP FAIL close goal: %', v_res; END IF;
    SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'status', 'active')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL set_savings_goal [reopen]: %', v_res; END IF;
    SELECT recurring_payment_id INTO v_rp_new FROM finance.savings_goals WHERE id = v_goal;
    IF v_rp_new = v_rp OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_new
         AND predecessor_id = v_rp AND status = 'active' AND valid_from = CURRENT_DATE AND valid_to IS NULL
         AND target_account_id = v_reserve) THEN
      RAISE EXCEPTION 'FAIL set_savings_goal [reopen Folge-rp]: %', (SELECT to_jsonb(r) FROM finance.recurring_payments r WHERE id = v_rp_new); END IF;
    IF (SELECT status::text FROM finance.savings_goals WHERE id = v_goal) IS DISTINCT FROM 'active' THEN
      RAISE EXCEPTION 'FAIL set_savings_goal [reopen goal.status]'; END IF;
    RAISE NOTICE 'PASS set_savings_goal [Reaktivierung nach Abschluss -> Folge-rp ab heute, Reserve-Ziel geerbt]';

    -- TEST 10 (Review): erneut abbrechen ohne neue Rate -> die Historie der alten rp zaehlt (Kette) -> Soft-Close,
    -- nie Hard-DELETE des Ziels.
    SELECT finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name','__test_ssg_goal__')) INTO v_res;
    IF v_res->>'action' IS DISTINCT FROM 'closed' OR NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal) THEN
      RAISE EXCEPTION 'FAIL close_savings_goal [Kette]: erwartet closed + Ziel bleibt, got %', v_res; END IF;
    RAISE NOTICE 'PASS close_savings_goal [Historie der Vorgaenger-rp zaehlt -> Soft-Close]';
  END;

  -- TEST 11 (Paket 3 / Review): Sparkonto muss ein aktives cash-/Festgeldkonto sein -> Depot / geschlossenes Konto ok:false
  DECLARE v_g2 INT; v_dep INT; v_closed INT; BEGIN
    SELECT (finance.fn_create_savings_goal(jsonb_build_object('name','__test_ssg_goal2__','target_amount',1000,
      'target_date','2027-12-31','monthly_savings_rate',50,'account_id',v_acct,'reserve_account_id',v_reserve,
      'schedule_day_of_month',1,'first_payment_date','2026-07-01'))->>'goal_id')::int INTO v_g2;
    IF v_g2 IS NULL THEN RAISE EXCEPTION 'SETUP FAIL goal2'; END IF;
    SELECT (finance.fn_create_account(jsonb_build_object('name','__test_ssg_dep__','account_type','stocks_depot',
      'currency','EUR','settlement_id',v_acct))->>'account_id')::int INTO v_dep;
    SELECT (finance.fn_create_account('{"name":"__test_ssg_closed__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_closed;
    UPDATE finance.accounts SET status = 'closed' WHERE id = v_closed;
    SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g2, 'reserve_account_id', v_dep)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL set_savings_goal [Sparkonto Depot]: %', v_res; END IF;
    SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g2, 'reserve_account_id', v_closed)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL set_savings_goal [Sparkonto geschlossen]: %', v_res; END IF;
    RAISE NOTICE 'PASS set_savings_goal [Sparkonto Depot / geschlossen -> ok:false]';
  END;
END $$;


-- TEST 9 (C8, Bugfix-Runde): savings_squeeze-Fold auch beim Aendern eines Ziels. Kontrollierter Cashflow
-- (alle rp neutralisiert; Dateiende, das ROLLBACK raeumt): Einnahmen 1000; Ziel mit Rate 200 -> gesund; Zielbetrag 90000 bis in 12 Monaten
-- -> Rate steigt weit ueber das Einkommen -> savings_squeeze im {ok:true}-Return.
DO $$
DECLARE
  v_res jsonb; v_fund int; v_pot int; v_goal int;
BEGIN
  UPDATE finance.recurring_payments SET status = 'paused';   -- kontrollierter Cashflow (Dateiende -> ROLLBACK raeumt)
  PERFORM core.fn_notify_resolve('finance', 'savings_squeeze');
  SELECT (finance.fn_create_account('{"name":"__test_ssg_fold_fund__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_fund;
  SELECT (finance.fn_create_account('{"name":"__test_ssg_fold_pot__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_pot;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__test_ssg_fold_inc__', v_fund, 1000, 'month', current_date, current_date);
  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_ssg_fold_goal__','target_amount',9000,
    'monthly_savings_rate',200,'account_id',v_fund,'reserve_account_id',v_pot,'schedule_day_of_month',1,
    'first_payment_date',current_date::text)) INTO v_res;
  IF v_res ? 'savings_squeeze' THEN RAISE EXCEPTION 'SETUP FAIL: Rate 200 darf nicht warnen, got %', v_res; END IF;
  v_goal := (v_res->>'goal_id')::int;

  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 90000,
    'target_date', (current_date + 365)::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true
     OR (v_res->'savings_squeeze'->>'account_change')::numeric IS NULL
     OR (v_res->'savings_squeeze'->>'account_change')::numeric >= 0 THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [fold]: Raten-Erhoehung muss savings_squeeze falten, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Raten-Erhoehung leert das Girokonto -> savings_squeeze im Return]';
END $$;

-- Ziele OHNE laufende Rate (Sparziel-Zweckbindung 2026-10-27):
--  (N1) Ziel erhoeht, keine Rate, kein Abbuchungskonto -> ok, code no_rate_running + required_monthly_rate, KEINE
--       angebliche new_monthly_rate (Bugfix: frueher still nicht gespeichert)
--  (N2) dasselbe mit account_id -> neue Rate (rp) vom Konto in den Topf (= Konto mit dem Ziel-Geld), Ziel zeigt darauf
--  (N3) ohne Topf und ohne reserve_account_id -> ok:false (Topf nennen)
DO $$
DECLARE
  v_giro INT; v_p2p INT; v_goal INT; v_goal2 INT; v_res JSONB; v_rp INT; v_months INT; v_exp NUMERIC;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__ssg2_giro__","account_type":"cash","opening_balance":9000}'::jsonb)->>'account_id')::int;
  v_p2p  := (finance.fn_create_account('{"name":"__ssg2_p2p__","account_type":"p2p","opening_balance":3000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__ssg2 Reise__', 3000, CURRENT_DATE + 400, 'active') RETURNING id INTO v_goal;
  PERFORM finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_p2p, 'amount', 3000));

  -- (N1)
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 4200));
  SELECT count(*) INTO v_months FROM generate_series(0, 20) k WHERE (core.fn_today() + make_interval(months => k))::date <= CURRENT_DATE + 400;
  v_exp := CEIL(1200.0 / v_months * 100) / 100;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'code' IS DISTINCT FROM 'no_rate_running'
     OR (v_res->>'required_monthly_rate')::numeric IS DISTINCT FROM v_exp OR v_res->>'new_monthly_rate' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [N1 no_rate_running]: % (erwartet %)', v_res, v_exp; END IF;

  -- (N2)
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'account_id', v_giro));
  SELECT recurring_payment_id INTO v_rp FROM finance.savings_goals WHERE id = v_goal;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_rp IS NULL OR (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM v_exp
     OR (SELECT target_account_id FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM v_p2p
     OR (SELECT account_id FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM v_giro
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -v_exp THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [N2 Rate starten]: % / rp %', v_res, v_rp; END IF;

  -- (N3)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__ssg2 Leer__', 1000, CURRENT_DATE + 400, 'active') RETURNING id INTO v_goal2;
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal2, 'account_id', v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [N3 ohne Topf]: %', v_res; END IF;

  RAISE NOTICE 'PASS set_savings_goal [ohne Rate: no_rate_running, Rate per account_id starten, ohne Topf abgelehnt]';
END $$;

-- Befund 2026-10-27: Rate nachtraeglich starten, waehrend schon ein Dauerauftrag vom Abbuchungskonto in den Topf
-- laeuft -> existing_transfer; replace_transfer=true -> die Rate fuehrt ihn fort (Betrag, Tag, naechster Termin).
DO $$
DECLARE
  v_r     JSONB;
  v_from  INT;
  v_pot   INT;
  v_goal  INT;
  v_old   INT;
  v_next1 DATE := (date_trunc('month', current_date) + interval '1 month')::date;
  v_rp    finance.recurring_payments%ROWTYPE;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__ssgr_from__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_from;
  SELECT (finance.fn_create_account('{"name":"__ssgr_pot__","account_type":"cash","account_holder":"Test","currency":"EUR","opening_balance":1000}'::jsonb)->>'account_id')::int INTO v_pot;
  v_r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__ssgr_uebertrag__','from_account_id',v_from,
           'to_account_id',v_pot,'amount',120,'schedule_unit','month','schedule_day_of_month',3,'first_payment_date',v_next1 + 2));
  v_old := (v_r->>'recurring_payment_id')::int;
  -- gedecktes Ziel (keine Rate, kein Guard), dann Zielbetrag erhoehen + Abbuchungskonto -> Rate starten
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__ssgr Ziel__','target_amount',500,
           'target_date',(v_next1 + interval '24 months')::date::text,'reserve_account_id',v_pot,'already_saved',500));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_r->>'recurring_payment_id' IS NOT NULL THEN
    RAISE EXCEPTION 'SETUP FAIL gedecktes Ziel: %', v_r; END IF;
  v_goal := (v_r->>'goal_id')::int;

  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',3500,'account_id',v_from));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'existing_transfer'
     OR (SELECT target_amount FROM finance.savings_goals WHERE id = v_goal) <> 500 THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [existing_transfer]: %', v_r; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Rate starten neben Dauerauftrag -> existing_transfer, kein Write]';

  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'target_amount',4500,'account_id',v_from,
           'replace_transfer','true'));
  SELECT * INTO v_rp FROM finance.recurring_payments WHERE id = (v_r->>'recurring_payment_id')::int;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'new_monthly_rate')::numeric <> 120
     OR (v_r->>'replaced_transfer_id')::int IS DISTINCT FROM v_old
     OR (v_r->>'required_monthly_rate')::numeric IS NULL
     OR v_rp.amount <> -120 OR v_rp.schedule_day_of_month IS DISTINCT FROM 3::smallint
     OR v_rp.first_payment_date <> v_next1 + 2 OR v_rp.target_account_id <> v_pot
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_old) THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [replace]: % rp=%', v_r, row_to_json(v_rp); END IF;
  RAISE NOTICE 'PASS set_savings_goal [replace -> Rate = Dauerauftrag (Betrag, Tag, Termin), noetige Rate zurueck, Alt weg]';
END $$;

-- ---------- Befund 2026-11-03: umgezogener Topf: ein altes Vorkommen vor dessen Stichtag -> reason lenkt aufs Ueberspringen ----------
DO $$
DECLARE
  T DATE := core.fn_today();
  v_due DATE := core.fn_today() - 25;
  v_giro INT; v_pot INT; v_new INT; v_goal INT; v_rp INT; v_r JSONB;
BEGIN
  WHILE extract(day FROM v_due) > 28 LOOP v_due := v_due - 1; END LOOP;
  v_giro := (finance.fn_create_account('{"name":"__ssg_ob_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__ssg_ob_pot__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_new  := (finance.fn_create_account(jsonb_build_object('name','__ssg_ob_new__','account_type','cash','currency','EUR','opening_balance',300,'opening_balance_date',(T-20)::text))->>'account_id')::int;
  v_r := finance.fn_create_savings_goal(jsonb_build_object('name','__ssg_ob_goal__','target_amount',5000,'target_date',(T+700)::text,
           'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',extract(day FROM v_due)::int,'first_payment_date',v_due::text));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP goal: %', v_r; END IF;
  v_goal := (v_r->>'goal_id')::int;
  v_rp := (v_r->>'recurring_payment_id')::int;
  PERFORM finance.fn_apply_goal_reserve(v_goal, v_new);
  v_r := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due));
  IF v_r->>'code' IS DISTINCT FROM 'before_opening' OR v_r->>'reason' NOT ILIKE '%skip%' THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [umgezogener Topf lenkt aufs Ueberspringen]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [umgezogener Topf kein Write]'; END IF;
  RAISE NOTICE 'PASS set_savings_goal [umgezogener Topf: before_opening, Termin ueberspringen]';
END $$;

ROLLBACK;

-- Sparziel kurz vor dem Termin im Depot (2026-11-06): depot_risk_accepted true ("das bleibt so") / false ("erinnere mich
-- wieder"), Ablehnungen no_depot_risk / already_accepted / no_depot_risk_decision, Datum vorziehen faltet, Umbenennen nicht.
BEGIN;
DO $$
DECLARE
  v_settle int; v_depot int; v_g int; v_far int; v_r jsonb; s record; v_cnt int;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__sgdr_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__sgdr_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  -- Ziel 10000 in 48 Monaten, 7000 im Depot: erlaubt 8000 -> im Pfad, nur weicher Hinweis
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgdr Auto__', 10000, (date_trunc('month', current_date) + interval '48 months' + interval '10 days')::date, 'active')
    RETURNING id INTO v_g;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_g, v_depot, 7000, 'EUR', 'manual');
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__sgdr Rente__', 10000, (current_date + interval '9 years')::date, 'active') RETURNING id INTO v_far;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_far, v_depot, 7000, 'EUR', 'manual');

  -- (R1) "das bleibt so" auch im Pfad -> Warnkarte (p_force), Stempel erst mit der gezeigten Lage
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT (v_r->'card_lines' @> '[{"value":"finance.note.goal_depot_risk"}]'::jsonb)
     OR v_r->>'card_approve_key' IS DISTINCT FROM 'finance.hitl.accept_depot_risk'
     OR (v_r->'effective'->'depot_risk_shown'->>'limit_eur')::numeric IS DISTINCT FROM 7000
     OR EXISTS (SELECT 1 FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g) THEN
    RAISE EXCEPTION 'FAIL set [R1 das bleibt so: Karte]: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'true',
           'depot_risk_shown', v_r->'effective'->'depot_risk_shown'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR NOT (v_r->'depot_risk' ? 'reminder_month')
     OR NOT (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_g)) THEN
    RAISE EXCEPTION 'FAIL set [R1 das bleibt so: Stempel]: %', v_r; END IF;
  RAISE NOTICE 'PASS set [R1 das bleibt so: Karte, dann Stempel]';

  -- (R2) schon bestaetigt -> already_accepted; (R3) ausserhalb des Fensters -> no_depot_risk
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'true'));
  IF v_r->>'code' IS DISTINCT FROM 'already_accepted' THEN RAISE EXCEPTION 'FAIL set [R2 already_accepted]: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_far, 'depot_risk_accepted', 'true'));
  IF v_r->>'code' IS DISTINCT FROM 'no_depot_risk' THEN RAISE EXCEPTION 'FAIL set [R3 no_depot_risk]: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'vielleicht'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL set [R3 ungueltiger Wert]: %', v_r; END IF;
  RAISE NOTICE 'PASS set [R2 already_accepted, R3 no_depot_risk + ungueltiger Wert]';

  -- (R4) Umbenennen faltet nicht; Datum nach hinten -> Stichtag wandert mit, Entscheidung bleibt
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'name', '__sgdr Auto neu__'));
  IF v_r->'card_lines' @> '[{"value":"finance.note.goal_depot_risk"}]'::jsonb OR v_r ? 'card_approve_key' THEN
    RAISE EXCEPTION 'FAIL set [R4 Umbenennen ohne Fold]: %', v_r; END IF;
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g,
            'target_date', to_char((date_trunc('month', current_date) + interval '50 months' + interval '10 days')::date, 'YYYY-MM-DD')));
  SELECT * INTO s FROM finance.fn_savings_goal_derisk_status(v_g);
  IF NOT s.accepted OR s.final_check_date IS DISTINCT FROM (date_trunc('month', current_date) + interval '38 months' + interval '10 days')::date THEN
    RAISE EXCEPTION 'FAIL set [R4 Datum nach hinten]: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS set [R4 Umbenennen ohne Fold, spaeteres Datum laesst die Entscheidung gelten]';

  -- (R5) "erinnere mich wieder" -> revoke + Hinweis; ohne gueltige Entscheidung -> no_depot_risk_decision
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'false'));
  SELECT count(*) INTO v_cnt FROM finance.savings_goal_risk_decisions WHERE savings_goal_id = v_g AND event = 'revoke';
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR v_cnt <> 1
     OR NOT (v_r->'card_lines' @> '[{"value":"finance.note.goal_depot_risk_revoked"}]'::jsonb)
     OR (SELECT accepted FROM finance.fn_savings_goal_derisk_status(v_g)) THEN
    RAISE EXCEPTION 'FAIL set [R5 revoke]: %', v_r; END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'false'));
  IF v_r->>'code' IS DISTINCT FROM 'no_depot_risk_decision' THEN RAISE EXCEPTION 'FAIL set [R5 no_depot_risk_decision]: %', v_r; END IF;
  -- Aufheben zusammen mit einer Datumsaenderung -> depot_risk_alone, ohne Write (Code-Review 2026-11-06)
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'depot_risk_accepted', 'false',
           'target_date', to_char((date_trunc('month', current_date) + interval '30 months')::date, 'YYYY-MM-DD')));
  IF v_r->>'code' IS DISTINCT FROM 'depot_risk_alone' THEN RAISE EXCEPTION 'FAIL set [R5 depot_risk_alone]: %', v_r; END IF;
  RAISE NOTICE 'PASS set [R5 erinnere mich wieder: revoke als neuer Eintrag; ohne Entscheidung abgelehnt]';

  -- (R6) Datum vorziehen in den Bereich ueber dem Pfad -> Warnkarte (Ziel in 20 Monaten, erlaubt 3333,33, 7000 im Depot)
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g,
           'target_date', to_char((date_trunc('month', current_date) + interval '20 months' + interval '10 days')::date, 'YYYY-MM-DD')));
  IF NOT (v_r->'card_lines' @> '[{"value":"finance.note.goal_depot_risk"}]'::jsonb)
     OR (v_r->'effective'->'depot_risk_shown'->>'allowed_eur')::numeric IS DISTINCT FROM 3333.33 THEN
    RAISE EXCEPTION 'FAIL set [R6 Datum vorgezogen]: %', v_r; END IF;
  RAISE NOTICE 'PASS set [R6 vorgezogenes Datum zeigt die Warnkarte]';
END $$;

-- (R7) Instandhaltungsruecklage wieder oeffnen: nur eine aktive Ruecklage DERSELBEN Immobilie sperrt, ein beliebiges
--      anderes aktives Ziel nicht; ohne gestoppte Quellen meldet der Return 0/false statt NULL.
DO $$
DECLARE v_re INT; v_g INT; v_r JSONB;
BEGIN
  INSERT INTO finance.real_estate (name) VALUES ('__ssg7 Haus__') RETURNING id INTO v_re;
  INSERT INTO finance.savings_goals (name, kind, real_estate_id, status)
    VALUES ('__ssg7 Ruecklage__', 'maintenance_reserve', v_re, 'cancelled') RETURNING id INTO v_g;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__ssg7 anderes Ziel__', 1000, current_date + 300, 'active');
  -- eine aktive Notreserve sperrt nur das Wiederoeffnen einer Notreserve, nicht das einer Instandhaltungsruecklage
  IF NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE kind = 'emergency_reserve' AND status = 'active') THEN
    INSERT INTO finance.savings_goals (name, kind, target_amount, status) VALUES ('__ssg7 Notreserve__', 'emergency_reserve', 3000, 'active');
  END IF;
  v_r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'status', 'active'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR (v_r->>'paused_plan_count')::int IS DISTINCT FROM 0 OR (v_r->>'paused_cash_rate')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set [R7 Ruecklage wieder oeffnen]: %', v_r; END IF;
  RAISE NOTICE 'PASS set [R7 Ruecklage oeffnen trotz anderem Ziel, Return 0/false]';
END $$;
ROLLBACK;

-- Neuberechnung ohne festen Tag: das Raster ist der Tag der ersten Rate (20.), nicht der heutige Tag.
BEGIN;
DO $$
DECLARE v_acct int; v_pot int; v_goal int; v_res jsonb; v_n int;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__ssg3_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__ssg3_p2p__","account_type":"p2p"}'::jsonb)->>'account_id')::int;
  v_goal := (finance.fn_create_savings_goal(jsonb_build_object('name','__ssg3_goal__','target_amount',5000,'target_date','2030-12-15',
              'monthly_savings_rate',200,'account_id',v_acct,'reserve_account_id',v_pot,'first_payment_date','2026-07-20'))->>'goal_id')::int;
  v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 6000));
  SELECT count(*) INTO v_n FROM generate_series(0, 80) k,
       LATERAL (SELECT (date_trunc('month', core.fn_today()) + make_interval(months => k, days => 19))::date AS d) x
   WHERE x.d >= core.fn_today() AND x.d <= DATE '2030-12-15';
  IF (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM CEIL(6000.0 / v_n * 100) / 100 THEN
    RAISE EXCEPTION 'FAIL set_savings_goal [Raster ohne Tag]: % (erwartet % Termine)', v_res, v_n; END IF;
  RAISE NOTICE 'PASS set_savings_goal [Raster ohne festen Tag]';

  -- Rate startet erst in 8 Monaten: nur die 5 Termine ab dem Start zaehlen
  DECLARE v_first date := (date_trunc('month', core.fn_today()) + interval '8 months')::date + 19; v_g int; BEGIN
    v_g := (finance.fn_create_savings_goal(jsonb_build_object('name','__ssg3_future__','target_amount',5000,'target_date',(v_first + interval '4 months' + interval '5 days')::date::text,
              'monthly_savings_rate',200,'account_id',v_acct,'reserve_account_id',v_pot,'first_payment_date',v_first::text))->>'goal_id')::int;
    v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'target_amount', 6000));
    IF (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM 1200 THEN RAISE EXCEPTION 'FAIL set_savings_goal [Start in der Zukunft]: %', v_res; END IF;
  END;

  -- Ziel genau am naechsten Abbuchungstag: Rate zaehlt mit, keine Ablehnung
  DECLARE v_next date := (date_trunc('month', core.fn_today() - 1) + interval '1 month')::date; v_g int; v_cnt int; BEGIN
    v_g := (finance.fn_create_savings_goal(jsonb_build_object('name','__ssg3_next__','target_amount',500,'target_date',(core.fn_today() + 200)::text,
              'monthly_savings_rate',50,'account_id',v_acct,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date','2026-07-01'))->>'goal_id')::int;
    v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'target_date', v_next::text));
    IF (v_res->>'ok')::boolean IS NOT TRUE OR (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM 500 THEN
      RAISE EXCEPTION 'FAIL set_savings_goal [Ziel am naechsten Termin]: %', v_res; END IF;
  END;

  -- heute schon gebuchte Rate zaehlt nicht noch einmal: heute (gebucht), +1, +2, +3 Monate -> 3 offene Termine
  DECLARE v_t date := core.fn_today(); v_g int; v_rp int; BEGIN
    v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__ssg3_booked__','target_amount',3000,'target_date',(v_t + interval '3 months' + interval '5 days')::date::text,
              'monthly_savings_rate',100,'account_id',v_acct,'reserve_account_id',v_pot,'first_payment_date',v_t::text));
    v_g := (v_res->>'goal_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date, group_id)
      VALUES (v_acct, -100, v_t, 'transfer', v_rp, v_t, gen_random_uuid());
    v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_g, 'target_amount', 6000));
    IF (v_res->>'new_monthly_rate')::numeric IS DISTINCT FROM 2000 THEN RAISE EXCEPTION 'FAIL set_savings_goal [gebuchte Rate]: %', v_res; END IF;
  END;
  RAISE NOTICE 'PASS set_savings_goal [Start in der Zukunft, Ziel am Termin, gebuchte Rate]';
END $$;
ROLLBACK;
