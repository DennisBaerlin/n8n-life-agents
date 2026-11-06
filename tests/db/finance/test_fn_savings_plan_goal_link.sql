-- tests/db/finance/test_fn_savings_plan_goal_link.sql
-- WS-B Stufe 2 (Phase S): Quellen-Verknuepfung. Ein Sparplan gehoert zu EINEM Sparziel
--   (savings_plans.savings_goal_id, FK ON DELETE SET NULL). fn_set_savings_goal traegt den
--   link/unlink-Pfad (Sparplan einem Ziel zuordnen/loesen). Geprueft:
--     1. link  -> savings_plans.savings_goal_id = goal.id
--     2. unlink -> savings_goal_id NULL
--     3. unlink-Guard: ein an Ziel A gebundener Plan laesst sich nicht ueber Ziel B loesen
--     4. link not-found / ambiguous -> {ok:false}, kein Write
--     5. Ziel-Hard-Delete mit verknuepftem Plan -> Plan UEBERLEBT entkoppelt (ON DELETE SET NULL)
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_result    JSONB;
  v_settle_id INT;
  v_depot_id  INT;
  v_goal_a    INT;
  v_goal_b    INT;
  v_plan_id   INT;
  v_linked    INT;
BEGIN
  -- Setup: Verrechnungskonto + Aktiendepot
  SELECT finance.fn_create_account(
    '{"name":"__test_link_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_link_depot__', 'account_type', 'stocks_depot',
    'account_holder', 'Test', 'currency', 'EUR', 'settlement_id', v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Zwei Sparziele
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_link_goal_a__', 'target_amount', 5000, 'target_date', (CURRENT_DATE + 365)::text,
    'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id', v_settle_id, 'schedule_day_of_month', 1, 'first_payment_date', (CURRENT_DATE + 5)::text
  )) INTO v_result;
  v_goal_a := (v_result->>'goal_id')::int;

  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name', '__test_link_goal_b__', 'target_amount', 3000, 'target_date', (CURRENT_DATE + 365)::text,
    'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id', v_settle_id, 'schedule_day_of_month', 1, 'first_payment_date', (CURRENT_DATE + 5)::text
  )) INTO v_result;
  v_goal_b := (v_result->>'goal_id')::int;

  -- Sparplan
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name', '__test_link_plan__', 'depot_name', '__test_link_depot__',
    'isin', 'IE00B4L5Y983', 'symbol', 'IUSQ', 'security_name', 'iShares MSCI World',
    'amount', 50, 'schedule_interval', 1, 'schedule_unit', 'month', 'first_payment_date', CURRENT_DATE::text
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan: %', v_result; END IF;
  v_plan_id := (v_result->>'savings_plan_id')::int;

  -- TEST 1: link -> savings_plans.savings_goal_id = goal_a
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_a, 'link_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL link [ok]: %', v_result; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS DISTINCT FROM v_goal_a THEN
    RAISE EXCEPTION 'FAIL link [savings_goal_id]: erwartet %, got %', v_goal_a, v_linked; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [link -> savings_goal_id=goal_a]';

  -- TEST 1b: re-link-Guard — ein an A gebundener Plan wird NICHT stillschweigend an B umgehaengt
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_b, 'link_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL re-link-Guard [erwartet ok=false]: %', v_result; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS DISTINCT FROM v_goal_a THEN
    RAISE EXCEPTION 'FAIL re-link-Guard [Bindung umgehaengt]: erwartet weiterhin %, got %', v_goal_a, v_linked; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [re-link an fremdes Ziel -> ok:false, Bindung bleibt A]';

  -- TEST 1c: erneutes link an DASSELBE Ziel A ist ein harmloser No-op (kein Guard-Treffer)
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_a, 'link_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL re-link same goal [erwartet ok=true]: %', v_result; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [erneutes link an dasselbe Ziel -> ok:true (No-op)]';

  -- TEST 2: unlink-Guard — ueber Ziel B loesen schlaegt fehl (Plan haengt an A), Bindung bleibt A
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_b, 'unlink_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL unlink-Guard [erwartet ok=false]: %', v_result; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS DISTINCT FROM v_goal_a THEN
    RAISE EXCEPTION 'FAIL unlink-Guard [Bindung veraendert]: erwartet weiterhin %, got %', v_goal_a, v_linked; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [unlink ueber fremdes Ziel -> ok:false, Bindung bleibt]';

  -- TEST 3: unlink ueber das eigene Ziel A -> savings_goal_id NULL
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_a, 'unlink_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL unlink [ok]: %', v_result; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL unlink [savings_goal_id]: erwartet NULL, got %', v_linked; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [unlink -> savings_goal_id NULL]';

  -- TEST 4: link not-found -> {ok:false}, kein Write
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_a, 'link_savings_plan_name', '__test_link_does_not_exist__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL link not-found [erwartet ok=false]: %', v_result; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL link not-found [kein Write]: savings_goal_id wurde gesetzt: %', v_linked; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [link not-found -> ok:false, kein Write]';

  -- TEST 5: Ziel-Hard-Delete mit verknuepftem Plan -> Plan UEBERLEBT entkoppelt (ON DELETE SET NULL).
  --   Re-link an A, dann Ziel A hart loeschen (kein getaggter Tx -> fn_close = Hard-DELETE).
  SELECT finance.fn_set_savings_goal(jsonb_build_object(
    'goal_id', v_goal_a, 'link_savings_plan_name', '__test_link_plan__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'SETUP FAIL re-link: %', v_result; END IF;

  SELECT finance.fn_close_savings_goal(jsonb_build_object(
    'savings_goal_name', '__test_link_goal_a__'
  )) INTO v_result;
  IF v_result->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL goal delete [erwartet action=deleted (Hard-DELETE)]: %', v_result; END IF;

  -- Plan existiert noch, savings_goal_id auf NULL gesetzt (FK SET NULL), Ziel weg
  IF NOT EXISTS (SELECT 1 FROM finance.savings_plans WHERE id = v_plan_id) THEN
    RAISE EXCEPTION 'FAIL goal delete [Plan mitgeloescht]: der verknuepfte Plan darf NICHT mit dem Ziel verschwinden'; END IF;
  SELECT savings_goal_id INTO v_linked FROM finance.savings_plans WHERE id = v_plan_id;
  IF v_linked IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL goal delete [SET NULL]: savings_goal_id erwartet NULL nach Ziel-Delete, got %', v_linked; END IF;
  IF EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal_a) THEN
    RAISE EXCEPTION 'FAIL goal delete [Ziel nicht weg]: Ziel A existiert noch'; END IF;
  RAISE NOTICE 'PASS fn_set_savings_goal [Ziel-Hard-Delete -> Plan ueberlebt entkoppelt (SET NULL)]';

END $$;

ROLLBACK;
