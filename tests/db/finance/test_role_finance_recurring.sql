-- tests/db/finance/test_role_finance_recurring.sql
-- Rollen-Perspektive der Dauerzahlungs- und Sparplan-Werkzeuge: alle Aufrufe laufen unter finance_rw (so wie die
--   Agent-Workflows), Fixture und Assertions als Superuser. Schreib-fns zuerst als Probelauf (core.fn_dry_run, rollt
--   zurueck), dann echt; Lese-fns direkt. Abgedeckt: Dauerzahlung anlegen/aendern/buchen/loeschen, Resolver, Faelligkeit,
--   Raten-Kette (lineage/current), Sparplan aendern/Ausfuehrung lesen+buchen/schliessen, fn_annual_equivalent.
--   Ein Block je Werkzeug-Familie; Namen sind eindeutig, alles laeuft in einer Transaktion mit ROLLBACK.
BEGIN;

-- Block 1: freistehende Dauerzahlung (Miete) von der Anlage bis zum Loeschen einer Fehlanlage
DO $$
DECLARE
  r       jsonb;
  v_acct  int;
  v_rp1   int;
  v_rp2   int;
  v_due   date := CURRENT_DATE - 5;
  v_id    int;
  v_cnt   int;
  v_ids   int[];
  v_cur   int;
  v_tx    int;
  v_del   int;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__role_rec_giro__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_acct;

  -- fn_create_recurring_payment: Probelauf schreibt nichts, echter Write legt die Zeile mit Vorzeichen -900 an
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_create_recurring_payment(jsonb)'::regprocedure, jsonb_build_object(
         'name','__role_rec_miete__','account_id',v_acct,'direction','expense','amount',900,
         'schedule_interval',1,'schedule_unit','month','first_payment_date',v_due::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__role_rec_miete__') THEN
    RAISE EXCEPTION 'FAIL [create_recurring_payment Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_recurring_payment(jsonb_build_object(
         'name','__role_rec_miete__','account_id',v_acct,'direction','expense','amount',900,
         'schedule_interval',1,'schedule_unit','month','first_payment_date',v_due::text));
  RESET ROLE;
  v_rp1 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_rp1 IS NULL
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments
                    WHERE id = v_rp1 AND account_id = v_acct AND amount = -900 AND status = 'active')
     THEN RAISE EXCEPTION 'FAIL [create_recurring_payment Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS create_recurring_payment (finance_rw)';

  -- fn_resolve_recurring_payment: Name -> genau ein Treffer mit der angelegten id
  SET LOCAL ROLE finance_rw;
  SELECT t.id, t.hit_count INTO v_id, v_cnt FROM finance.fn_resolve_recurring_payment('__role_rec_miete__', FALSE) t;
  RESET ROLE;
  IF v_id IS DISTINCT FROM v_rp1 OR v_cnt IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [resolve_recurring_payment finance_rw]: id=% hit_count=% erwartet % / 1', v_id, v_cnt, v_rp1; END IF;
  RAISE NOTICE 'PASS resolve_recurring_payment (finance_rw)';

  -- fn_recurring_due_open: das Vorkommen vor 5 Tagen ist offen (1-arg-Scheduler-Sicht und 2-arg-Zeitraum)
  SET LOCAL ROLE finance_rw;
  SELECT count(*) INTO v_cnt FROM finance.fn_recurring_due_open(CURRENT_DATE) o
   WHERE o.recurring_payment_id = v_rp1 AND o.due_date = v_due;
  RESET ROLE;
  IF v_cnt IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [recurring_due_open 1-arg finance_rw]: % Treffer, erwartet 1', v_cnt; END IF;
  SET LOCAL ROLE finance_rw;
  SELECT count(*) INTO v_cnt FROM finance.fn_recurring_due_open(v_due - 1, v_due + 1) o
   WHERE o.recurring_payment_id = v_rp1 AND o.due_date = v_due;
  RESET ROLE;
  IF v_cnt IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [recurring_due_open 2-arg finance_rw]: % Treffer, erwartet 1', v_cnt; END IF;
  RAISE NOTICE 'PASS recurring_due_open (finance_rw)';

  -- fn_book_recurring_occurrence: bucht -900 mit Faelligkeits-Stempel, das Vorkommen ist danach nicht mehr offen
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_recurring_occurrence(jsonb)'::regprocedure, jsonb_build_object(
         'recurring_payment_id', v_rp1, 'due_date', v_due::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = v_rp1) THEN
    RAISE EXCEPTION 'FAIL [book_recurring_occurrence Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp1, 'due_date', v_due::text));
  RESET ROLE;
  v_tx := (r->>'transaction_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_tx IS NULL
     OR NOT EXISTS (SELECT 1 FROM finance.transactions
                    WHERE id = v_tx AND account_id = v_acct AND amount = -900
                      AND recurring_payment_id = v_rp1 AND recurring_due_date = v_due)
     OR EXISTS (SELECT 1 FROM finance.fn_recurring_due_open(CURRENT_DATE) o
                WHERE o.recurring_payment_id = v_rp1 AND o.due_date = v_due)
     THEN RAISE EXCEPTION 'FAIL [book_recurring_occurrence Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS book_recurring_occurrence (finance_rw)';

  -- fn_set_recurring_payment: neuer Betrag ab Stichtag = Validity-Split, neue Zeile -950 mit Vorgaenger rp1
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_recurring_payment(jsonb)'::regprocedure, jsonb_build_object(
         'recurring_payment_id', v_rp1, 'amount', 950, 'valid_from', (CURRENT_DATE + 20)::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM finance.recurring_payments WHERE predecessor_id = v_rp1) <> 0 THEN
    RAISE EXCEPTION 'FAIL [set_recurring_payment Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_recurring_payment(jsonb_build_object(
         'recurring_payment_id', v_rp1, 'amount', 950, 'valid_from', (CURRENT_DATE + 20)::text));
  RESET ROLE;
  v_rp2 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'split')::boolean IS NOT TRUE OR v_rp2 IS NULL OR v_rp2 = v_rp1
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments
                    WHERE id = v_rp2 AND predecessor_id = v_rp1 AND amount = -950 AND valid_from = CURRENT_DATE + 20)
     THEN RAISE EXCEPTION 'FAIL [set_recurring_payment Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS set_recurring_payment (finance_rw)';

  -- fn_recurring_lineage: beide Glieder der Kette, von jedem Ende aus gelesen
  SET LOCAL ROLE finance_rw;
  SELECT array_agg(x ORDER BY x) INTO v_ids FROM finance.fn_recurring_lineage(v_rp1) x;
  RESET ROLE;
  IF v_ids IS DISTINCT FROM ARRAY[LEAST(v_rp1, v_rp2), GREATEST(v_rp1, v_rp2)] THEN
    RAISE EXCEPTION 'FAIL [recurring_lineage finance_rw]: % erwartet {%,%}', v_ids, v_rp1, v_rp2; END IF;
  RAISE NOTICE 'PASS recurring_lineage (finance_rw)';

  -- fn_recurring_current: heute gilt rp1 (-900), ab dem Stichtag rp2 (-950)
  SET LOCAL ROLE finance_rw;
  v_cur := finance.fn_recurring_current(v_rp1, CURRENT_DATE);
  RESET ROLE;
  IF v_cur IS DISTINCT FROM v_rp1 THEN RAISE EXCEPTION 'FAIL [recurring_current heute finance_rw]: % erwartet %', v_cur, v_rp1; END IF;
  SET LOCAL ROLE finance_rw;
  v_cur := finance.fn_recurring_current(v_rp1, CURRENT_DATE + 25);
  RESET ROLE;
  IF v_cur IS DISTINCT FROM v_rp2 THEN RAISE EXCEPTION 'FAIL [recurring_current Stichtag finance_rw]: % erwartet %', v_cur, v_rp2; END IF;
  RAISE NOTICE 'PASS recurring_current (finance_rw)';

  -- fn_delete_recurring_payment: eine referenzfreie Fehlanlage (ohne Buchung) wird hart geloescht
  r := finance.fn_create_recurring_payment(jsonb_build_object(
         'name','__role_rec_fehlanlage__','account_id',v_acct,'direction','expense','amount',12,
         'schedule_interval',1,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 3)::text));
  v_del := (r->>'recurring_payment_id')::int;
  IF v_del IS NULL THEN RAISE EXCEPTION 'SETUP FAIL [Fehlanlage]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_delete_recurring_payment(jsonb)'::regprocedure,
         jsonb_build_object('recurring_payment_name','__role_rec_fehlanlage__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_del) THEN
    RAISE EXCEPTION 'FAIL [delete_recurring_payment Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_delete_recurring_payment(jsonb_build_object('recurring_payment_name','__role_rec_fehlanlage__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'deleted' OR (r->>'recurring_payment_id')::int IS DISTINCT FROM v_del
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_del)
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp1) THEN
    RAISE EXCEPTION 'FAIL [delete_recurring_payment Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment (finance_rw)';
END $$;

-- Block 2: Sparplan (Depot mit Verrechnungskonto): Ausfuehrung lesen und buchen, Betrag aendern, schliessen
DO $$
DECLARE
  r        jsonb;
  v_settle int;
  v_plan   int;
  v_rp1    int;
  v_rp2    int;
  v_plan2  int;
  v_rp_del int;
  v_tx     int;
  v_due    date := CURRENT_DATE - 2;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__role_sp_settle__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_settle;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__role_sp_depot__','account_type','stocks_depot',
    'currency','EUR','settlement_id', v_settle));
  -- Plan 1: eine Ausfuehrung vor 2 Tagen offen; Plan 2: noch nie gebucht (Hard-Delete-Pfad beim Schliessen)
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__role_sp_etf__','depot_name','__role_sp_depot__',
         'isin','IE00B3RBWM25','symbol','VWCE','security_name','Vanguard FTSE All-World','amount',50,
         'schedule_interval',1,'schedule_unit','month','first_payment_date',v_due::text));
  v_plan := (r->>'savings_plan_id')::int;
  v_rp1  := (r->>'recurring_payment_id')::int;
  IF v_plan IS NULL THEN RAISE EXCEPTION 'SETUP FAIL [Plan 1]: %', r; END IF;
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__role_sp_leer__','depot_name','__role_sp_depot__',
         'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',25,
         'schedule_interval',1,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 10)::text));
  v_plan2  := (r->>'savings_plan_id')::int;
  v_rp_del := (r->>'recurring_payment_id')::int;
  IF v_plan2 IS NULL THEN RAISE EXCEPTION 'SETUP FAIL [Plan 2]: %', r; END IF;

  -- fn_savings_plan_next_execution: offenes Vorkommen mit Planbetrag, Verrechnungskonto und Waehrung
  SET LOCAL ROLE finance_rw;
  r := finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__role_sp_etf__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'due_date')::date IS DISTINCT FROM v_due
     OR (r->>'recurring_payment_id')::int IS DISTINCT FROM v_rp1 OR (r->>'plan_amount')::numeric IS DISTINCT FROM 50
     OR (r->>'settlement_account_id')::int IS DISTINCT FROM v_settle OR r->>'currency' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [savings_plan_next_execution finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS savings_plan_next_execution (finance_rw)';

  -- fn_book_savings_plan_execution: 2 Stueck zu 25 = -50 auf dem Verrechnungskonto, Stempel auf dem Ketten-Glied
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_savings_plan_execution(jsonb)'::regprocedure, jsonb_build_object(
         'savings_plan_name','__role_sp_etf__','shares',2,'price_per_share',25));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE recurring_payment_id = v_rp1) THEN
    RAISE EXCEPTION 'FAIL [book_savings_plan_execution Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_savings_plan_execution(jsonb_build_object(
         'savings_plan_name','__role_sp_etf__','shares',2,'price_per_share',25));
  RESET ROLE;
  v_tx := (r->>'buy_tx_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_tx IS NULL OR (r->>'total_cost')::numeric IS DISTINCT FROM 50
     OR (r->>'due_date')::date IS DISTINCT FROM v_due
     OR NOT EXISTS (SELECT 1 FROM finance.transactions
                    WHERE id = v_tx AND amount = -50 AND recurring_payment_id = v_rp1 AND recurring_due_date = v_due)
     OR (SELECT shares FROM finance.depot_holdings WHERE id = (r->>'holding_id')::int) IS DISTINCT FROM 2
     THEN RAISE EXCEPTION 'FAIL [book_savings_plan_execution Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS book_savings_plan_execution (finance_rw)';

  -- nach der Buchung ist nichts mehr offen
  SET LOCAL ROLE finance_rw;
  r := finance.fn_savings_plan_next_execution(jsonb_build_object('savings_plan_name','__role_sp_etf__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [savings_plan_next_execution nach Buchung]: %', r; END IF;

  -- fn_set_savings_plan: neuer Betrag ab Stichtag = Split, plan.recurring_payment_id zeigt auf die neue Zeile (-100)
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_savings_plan(jsonb)'::regprocedure, jsonb_build_object(
         'savings_plan_name','__role_sp_etf__','new_amount',100,'valid_from',(CURRENT_DATE + 20)::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT recurring_payment_id FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM v_rp1 THEN
    RAISE EXCEPTION 'FAIL [set_savings_plan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_savings_plan(jsonb_build_object(
         'savings_plan_name','__role_sp_etf__','new_amount',100,'valid_from',(CURRENT_DATE + 20)::text));
  RESET ROLE;
  v_rp2 := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'split')::boolean IS NOT TRUE OR v_rp2 IS NULL OR v_rp2 = v_rp1
     OR (SELECT recurring_payment_id FROM finance.savings_plans WHERE id = v_plan) IS DISTINCT FROM v_rp2
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp2 AND predecessor_id = v_rp1 AND amount = -100)
     THEN RAISE EXCEPTION 'FAIL [set_savings_plan Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS set_savings_plan (finance_rw)';

  -- fn_close_savings_plan: Plan ohne Buchung wird samt rp hart geloescht ...
  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_close_savings_plan(jsonb)'::regprocedure,
         jsonb_build_object('savings_plan_name','__role_sp_leer__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.savings_plans WHERE id = v_plan2) THEN
    RAISE EXCEPTION 'FAIL [close_savings_plan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__role_sp_leer__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'deleted' OR (r->>'tx_count')::int <> 0
     OR EXISTS (SELECT 1 FROM finance.savings_plans WHERE id = v_plan2)
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_del) THEN
    RAISE EXCEPTION 'FAIL [close_savings_plan Write ohne Buchung finance_rw]: %', r; END IF;

  -- ... Plan mit Buchung wird nur beendet (pausiert), die Historie bleibt
  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_savings_plan(jsonb_build_object('savings_plan_name','__role_sp_etf__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'closed' OR (r->>'tx_count')::int <> 1
     OR (SELECT status::text FROM finance.savings_plans WHERE id = v_plan) <> 'paused'
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = v_tx) THEN
    RAISE EXCEPTION 'FAIL [close_savings_plan Write mit Buchung finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS close_savings_plan (finance_rw)';
END $$;

-- Block 3: fn_annual_equivalent (reine Rechenfunktion, in Views/Workflow-Queries unter finance_rw gelesen)
DO $$
DECLARE
  v_month numeric;
  v_quart numeric;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_month := finance.fn_annual_equivalent(30, 1, 'month', 1);
  RESET ROLE;
  SET LOCAL ROLE finance_rw;
  v_quart := finance.fn_annual_equivalent(60, 3, 'month', 1);
  RESET ROLE;
  IF v_month IS DISTINCT FROM 360.00 OR v_quart IS DISTINCT FROM 240.00 THEN
    RAISE EXCEPTION 'FAIL [annual_equivalent finance_rw]: monatlich=% (erwartet 360) quartalsweise=% (erwartet 240)', v_month, v_quart; END IF;
  RAISE NOTICE 'PASS annual_equivalent (finance_rw)';
END $$;

ROLLBACK;
