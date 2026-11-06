-- tests/db/finance/test_fn_close_account.sql
-- Testet fn_close_account: Status-Wechsel, Trigger blockiert neue TX, Guards
BEGIN;

DO $$
DECLARE
  v_result      JSONB;
  v_acct_id     INT;
  v_status      TEXT;
  v_settle_id2  INT;
  v_depot_id2   INT;
BEGIN

  -- Setup: Konto anlegen
  SELECT finance.fn_create_account(
    '{"name":"__test_close_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- TEST 1: Konto schliessen
  SELECT finance.fn_close_account(jsonb_build_object(
    'account_id',   v_acct_id,
    'closure_date', CURRENT_DATE::text,
    'notes',        'Test-Schliessung'
  )) INTO v_result;

  IF (v_result->>'account_id')::int IS DISTINCT FROM v_acct_id THEN
    RAISE EXCEPTION 'FAIL fn_close_account: falsches account_id im Result, got %', v_result;
  END IF;
  IF v_result->>'status' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL fn_close_account: status != closed, got %', v_result->>'status';
  END IF;
  RAISE NOTICE 'PASS fn_close_account [status=closed im Result]';

  -- Assert: DB-Status wirklich 'closed'
  SELECT status::text INTO v_status FROM finance.accounts WHERE id = v_acct_id;
  IF v_status IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL fn_close_account [DB-Status]: erwartet closed, got %', v_status;
  END IF;
  RAISE NOTICE 'PASS fn_close_account [DB status=closed]';

  -- TEST 2: Trigger blockiert INSERT auf geschlossenem Konto
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
    VALUES (v_acct_id, 100, CURRENT_DATE, 'other', 'Post-Close-TX');
    RAISE EXCEPTION 'FAIL fn_close_account [insert_guard]: INSERT auf closed-Konto haette fehlschlagen muessen';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%closed%' THEN
        RAISE NOTICE 'PASS fn_close_account [insert_guard]: Trigger blockiert (%).', SQLERRM;
      ELSE
        RAISE EXCEPTION 'FAIL fn_close_account [insert_guard]: falscher Fehler: %', SQLERRM;
      END IF;
  END;

  -- TEST 3: Guard - bereits geschlossenes Konto erneut schliessen
  BEGIN
    SELECT finance.fn_close_account(jsonb_build_object(
      'account_id',   v_acct_id,
      'closure_date', CURRENT_DATE::text,
      'notes',        ''
    )) INTO v_result;
    RAISE EXCEPTION 'FAIL fn_close_account [double_close_guard]: Guard haette ablehnen muessen';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%already closed%' THEN
        RAISE NOTICE 'PASS fn_close_account [double_close_guard]: %.', SQLERRM;
      ELSE
        RAISE EXCEPTION 'FAIL fn_close_account [double_close_guard]: falscher Fehler: %', SQLERRM;
      END IF;
  END;

  -- TEST 4: Guard - nicht existierendes Konto
  BEGIN
    SELECT finance.fn_close_account(jsonb_build_object(
      'account_id',   99999999,
      'closure_date', CURRENT_DATE::text,
      'notes',        ''
    )) INTO v_result;
    RAISE EXCEPTION 'FAIL fn_close_account [not_found_guard]: Guard haette ablehnen muessen';
  EXCEPTION
    WHEN others THEN
      IF SQLERRM LIKE '%not found%' THEN
        RAISE NOTICE 'PASS fn_close_account [not_found_guard]: %.', SQLERRM;
      ELSE
        RAISE EXCEPTION 'FAIL fn_close_account [not_found_guard]: falscher Fehler: %', SQLERRM;
      END IF;
  END;

  -- TEST 5: Verrechnungskonto eines aktiven Depots -> {ok:false} (korrigierbar, kein RAISE)
  SELECT finance.fn_create_account(
    '{"name":"__test_close_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id2 := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_close_depot__', 'account_type', 'stocks_depot', 'account_holder', 'Test',
    'currency', 'EUR', 'settlement_id', v_settle_id2
  )) INTO v_result;
  v_depot_id2 := (v_result->>'account_id')::int;

  SELECT finance.fn_close_account(jsonb_build_object(
    'account_id', v_settle_id2, 'closure_date', CURRENT_DATE::text, 'notes', ''
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_close_account [settlement_dep]: erwartet ok=false, got %', v_result;
  END IF;
  IF (v_result->>'depot_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_close_account [settlement_dep]: depot_count erwartet 1, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_close_account [settlement_dep -> ok:false, depot_count=%]', v_result->>'depot_count';

  -- TEST 6 (Audit F6): Konto mit Guthaben -> {ok:false} + blockers, Konto bleibt aktiv (vorher verschwanden 3.000 EUR
  --   still aus dem Vermoegen). Details der Blocker-Arten -> test_fn_get_account_close_blockers.sql.
  DECLARE v_money INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_close_money__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_money;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_money, 3000, CURRENT_DATE, 'other');
    SELECT finance.fn_close_account(jsonb_build_object('account_id', v_money, 'closure_date', CURRENT_DATE::text, 'notes', '')) INTO v_result;
    SELECT status::text INTO v_status FROM finance.accounts WHERE id = v_money;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_status IS DISTINCT FROM 'active'
       OR (v_result->'blockers'->0->>'balance')::numeric IS DISTINCT FROM 3000 THEN
      RAISE EXCEPTION 'FAIL fn_close_account [Guthaben]: erwartet ok=false, active, balance-Blocker 3000, got % / %', v_result, v_status; END IF;
    RAISE NOTICE 'PASS fn_close_account [Guthaben 3000 -> ok:false, Konto bleibt aktiv]';
  END;

END $$;

ROLLBACK;
