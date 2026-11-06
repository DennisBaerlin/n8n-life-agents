-- tests/db/finance/test_fn_close_savings_plan.sql
-- Testet fn_close_savings_plan: Hard-DELETE (keine Buchungen), Soft-Close (Buchungen vorhanden)
BEGIN;

DO $$
DECLARE
  v_result       JSONB;
  v_settle_id    INT;
  v_depot_id     INT;
  v_plan_a_id    INT;
  v_plan_b_id    INT;
  v_rp_a_id      INT;
  v_rp_b_id      INT;
  v_plan_status  TEXT;
  v_rp_valid_to  DATE;
  v_plan_count   INT;
  v_rp_count     INT;
BEGIN

  -- Setup: Verrechnungskonto + Aktiendepot
  SELECT finance.fn_create_account(
    '{"name":"__test_csp_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_csp_depot__',
    'account_type', 'stocks_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Setup Plan A: keine Buchungen -> Hard-DELETE-Kandidat
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_csp_plan_a__',
    'depot_name',        '__test_csp_depot__',
    'isin',              'IE00B3RBWM25',
    'symbol',            'VWCE',
    'security_name',     'Vanguard FTSE All-World',
    'amount',            100,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', '2026-08-01'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan [plan A]: %', v_result->>'reason';
  END IF;
  v_plan_a_id := (v_result->>'savings_plan_id')::int;
  v_rp_a_id   := (v_result->>'recurring_payment_id')::int;

  -- Setup Plan B: eine Buchung -> Soft-Close-Kandidat
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',              '__test_csp_plan_b__',
    'depot_name',        '__test_csp_depot__',
    'isin',              'IE00B4L5Y983',
    'symbol',            'IWDA',
    'security_name',     'iShares Core MSCI World',
    'amount',            50,
    'schedule_interval', 1,
    'schedule_unit',     'month',
    'first_payment_date', '2026-08-01'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'SETUP FAIL fn_create_savings_plan [plan B]: %', v_result->>'reason';
  END IF;
  v_plan_b_id := (v_result->>'savings_plan_id')::int;
  v_rp_b_id   := (v_result->>'recurring_payment_id')::int;

  -- Setup Plan B: direkt eine Buchung eintragen (category=other, damit kein Holding-FK nötig)
  INSERT INTO finance.transactions
    (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES
    (v_settle_id, -50, CURRENT_DATE - 30, 'other', v_rp_b_id, 'Test-Buchung Sparplan B');

  -- TEST 1: Hard-DELETE (keine Buchungen) -> action='deleted', Plan + RP nicht mehr in DB
  SELECT finance.fn_close_savings_plan(
    jsonb_build_object('savings_plan_name', '__test_csp_plan_a__')
  ) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [hard-delete]: ok=false, reason=%',
      v_result->>'reason';
  END IF;
  IF (v_result->>'action') IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [hard-delete action]: erwartet deleted, got %',
      v_result->>'action';
  END IF;
  IF (v_result->>'tx_count')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [hard-delete tx_count]: erwartet 0, got %',
      v_result->>'tx_count';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [hard-delete]: action=%, tx_count=%',
    v_result->>'action', v_result->>'tx_count';

  -- Assert: Plan-Zeile nicht mehr in DB
  SELECT COUNT(*) INTO v_plan_count
  FROM finance.savings_plans WHERE id = v_plan_a_id;
  IF v_plan_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [hard-delete plan gone]: plan_a_id noch in DB';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [Plan A aus DB entfernt]';

  -- Assert: RP-Zeile nicht mehr in DB
  SELECT COUNT(*) INTO v_rp_count
  FROM finance.recurring_payments WHERE id = v_rp_a_id;
  IF v_rp_count IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [hard-delete rp gone]: rp_a noch in DB';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [RP Plan A aus DB entfernt]';

  -- TEST 2: Soft-Close (Buchung vorhanden) -> action='closed', plan.status=paused, rp.valid_to gesetzt
  SELECT finance.fn_close_savings_plan(
    jsonb_build_object('savings_plan_name', '__test_csp_plan_b__')
  ) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close]: ok=false, reason=%',
      v_result->>'reason';
  END IF;
  IF (v_result->>'action') IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close action]: erwartet closed, got %',
      v_result->>'action';
  END IF;
  IF (v_result->>'tx_count')::int < 1 THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close tx_count]: erwartet >=1, got %',
      v_result->>'tx_count';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [soft-close]: action=%, tx_count=%',
    v_result->>'action', v_result->>'tx_count';

  -- Assert: plan.status = 'paused' (Soft-Close lässt Zeile erhalten)
  SELECT status::text INTO v_plan_status
  FROM finance.savings_plans WHERE id = v_plan_b_id;
  IF v_plan_status IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close plan.status]: erwartet paused, got %',
      v_plan_status;
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [plan.status=paused]';

  -- Assert: rp.valid_to gesetzt (RP beendet, taucht nicht mehr in fn_recurring_due_open auf)
  SELECT valid_to INTO v_rp_valid_to
  FROM finance.recurring_payments WHERE id = v_rp_b_id;
  IF v_rp_valid_to IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close rp.valid_to]: valid_to nicht gesetzt';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [rp.valid_to=%]', v_rp_valid_to;

  -- Assert: Plan B noch in DB (Soft-Close, nicht gelöscht)
  SELECT COUNT(*) INTO v_plan_count
  FROM finance.savings_plans WHERE id = v_plan_b_id;
  IF v_plan_count IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [soft-close plan bleibt]: plan_b_id nicht in DB';
  END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [Plan B bleibt in DB (Soft-Close)]';

  -- TEST 3: Plan nicht gefunden -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz:
  -- ein unbekannter Name ist nutzer-korrigierbar und kommt im Probelauf VOR der Karte zurueck, kein Owner-Alarm)
  SELECT finance.fn_close_savings_plan(
    jsonb_build_object('savings_plan_name', '__test_csp_plan_notfound__')
  ) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT LIKE '%not found%'
     OR NOT (v_result ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL fn_close_savings_plan [not-found -> ok:false]: %', v_result; END IF;
  RAISE NOTICE 'PASS fn_close_savings_plan [not-found -> ok:false]';

END $$;

ROLLBACK;
