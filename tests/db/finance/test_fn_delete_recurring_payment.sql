-- tests/db/finance/test_fn_delete_recurring_payment.sql
-- Testet fn_delete_recurring_payment: Hard-DELETE (standalone), Guards (entitaets-besessen /
-- gebuchte Transaktion), not-found. Nur STANDALONE rp loeschbar.
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_acct  INT;
  v_rp    INT;
  v_rp_tx INT;
  v_cnt   INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_drp_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_acct;

  -- Standalone rp -> loeschbar
  SELECT (finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__test_drp_standalone__','account_id',v_acct,'direction','expense','amount','50',
    'schedule_unit','month','schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text
  ))->>'recurring_payment_id')::int INTO v_rp;

  -- Entitaets-besessen: Versicherung legt rp 'Versicherung __test_drp_ins__' an
  PERFORM finance.fn_create_insurance(jsonb_build_object(
    'name','__test_drp_ins__','policyholder','T','annual_premium','120',
    'schedule_unit','month','schedule_day_of_month','1','valid_from',CURRENT_DATE::text,
    'debit_account_id',v_acct,'recurring_amount','-10'));

  -- Standalone rp MIT gebuchter Transaktion -> Guard
  SELECT (finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__test_drp_booked__','account_id',v_acct,'direction','expense','amount','30',
    'schedule_unit','month','schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text
  ))->>'recurring_payment_id')::int INTO v_rp_tx;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id)
  VALUES (v_acct, -30, CURRENT_DATE, 'other', v_rp_tx);

  -- TEST 1: Hard-DELETE standalone
  SELECT finance.fn_delete_recurring_payment('{"recurring_payment_name":"__test_drp_standalone__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_recurring_payment [rp noch da]'; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [Hard-DELETE standalone]';

  -- TEST 2: Guard entitaets-besessen -> {ok:false}, rp bleibt
  SELECT finance.fn_delete_recurring_payment('{"recurring_payment_name":"Versicherung __test_drp_ins__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [owned-guard]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [owned-guard: ok=false]';

  -- TEST 3: Guard gebuchte Transaktion -> {ok:false}
  SELECT finance.fn_delete_recurring_payment('{"recurring_payment_name":"__test_drp_booked__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [tx-guard]: erwartet ok=false, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp_tx;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_recurring_payment [rp mit tx faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [tx-guard: ok=false]';

  -- TEST 4: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_delete_recurring_payment('{"recurring_payment_name":"__test_drp_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [not-found -> ok:false]';
END $$;

-- Livebefund 2026-10-27: der Agent loeschte einen Uebertrag auf das Verrechnungskonto eines Kinder-Sparplans als
-- "Duplikat" einer Ziel-Rate. Zubringer (Sparplan-Verrechnungskonto, Ziel-Topf) -> feeds_savings ohne Bestaetigung.
DO $$
DECLARE
  v_r      JSONB;
  v_giro   INT; v_kid INT; v_pot INT; v_other INT;
  v_next1  DATE := (date_trunc('month', current_date) + interval '1 month')::date;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__drf_giro__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__drf_kid_cash__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_kid;
  SELECT (finance.fn_create_account('{"name":"__drf_pot__","account_type":"cash","account_holder":"Test","currency":"EUR","opening_balance":800}'::jsonb)->>'account_id')::int INTO v_pot;
  SELECT (finance.fn_create_account('{"name":"__drf_other__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_other;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__drf_depot__', 'stocks_depot', 'EUR', 'active', v_kid);
  PERFORM finance.fn_create_savings_plan(jsonb_build_object('name','__drf_plan__','depot_name','__drf_depot__',
    'isin','IE00B4L5Y983','symbol','IWDA','security_name','Beispiel World','amount',50,'schedule_unit','month',
    'first_payment_date',v_next1 + 1));
  PERFORM finance.fn_create_savings_goal(jsonb_build_object('name','__drf Ziel__','target_amount',800,
    'target_date',(v_next1 + 365)::text,'reserve_account_id',v_pot,'already_saved',800));
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','__drf_zum_sparplan__','from_account_id',v_giro,
    'to_account_id',v_kid,'amount',150,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next1));
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','__drf_zum_topf__','from_account_id',v_giro,
    'to_account_id',v_pot,'amount',100,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next1));
  PERFORM finance.fn_create_recurring_transfer(jsonb_build_object('name','__drf_sonst__','from_account_id',v_giro,
    'to_account_id',v_other,'amount',20,'schedule_unit','month','schedule_day_of_month',1,'first_payment_date',v_next1));

  v_r := finance.fn_delete_recurring_payment('{"recurring_payment_name":"__drf_zum_sparplan__"}'::jsonb);
  IF v_r->>'code' IS DISTINCT FROM 'feeds_savings' OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__drf_zum_sparplan__') THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [Zubringer Sparplan]: %', v_r; END IF;
  v_r := finance.fn_delete_recurring_payment('{"recurring_payment_name":"__drf_zum_topf__"}'::jsonb);
  IF v_r->>'code' IS DISTINCT FROM 'feeds_savings' THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [Zubringer Ziel-Topf]: %', v_r; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [Zubringer (Sparplan-Konto, Ziel-Topf) -> feeds_savings, nichts geloescht]';

  v_r := finance.fn_delete_recurring_payment('{"recurring_payment_name":"__drf_zum_sparplan__","confirm_feeds_savings":"true"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__drf_zum_sparplan__') THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [Zubringer bestaetigt]: %', v_r; END IF;
  v_r := finance.fn_delete_recurring_payment('{"recurring_payment_name":"__drf_sonst__"}'::jsonb);
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL delete_recurring_payment [normaler Transfer]: %', v_r; END IF;
  RAISE NOTICE 'PASS delete_recurring_payment [mit Bestaetigung geloescht; normaler Transfer unveraendert loeschbar]';
END $$;

ROLLBACK;
