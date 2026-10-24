-- tests/db/finance/test_fn_close_pension.sql
-- Testet fn_close_pension: Hard-DELETE (mit + ohne RP), Soft-Close (Buchungen vorhanden), not-found
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_p_a    INT; v_rp_a INT;
  v_p_b    INT; v_rp_b INT;
  v_p_c    INT;
  v_cnt    INT; v_status TEXT; v_valid_to DATE; v_rp_status TEXT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_cp_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- Pension A: mit Beitrag (RP), keine Buchung -> Hard-DELETE
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','__test_cp_a__','pension_type','private','contribution_amount',150,
    'debit_account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_p_a := (v_res->>'pension_id')::int; v_rp_a := (v_res->>'recurring_payment_id')::int;

  -- Pension B: mit Beitrag + eine Buchung -> Soft-Close
  SELECT finance.fn_create_pension(jsonb_build_object(
    'name','__test_cp_b__','pension_type','ruerup','contribution_amount',200,
    'debit_account_id',v_acct,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_p_b := (v_res->>'pension_id')::int; v_rp_b := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -200, CURRENT_DATE - 30, 'other', v_rp_b, 'Test-Beitrag');

  -- Pension C: OHNE Beitrag (rp NULL) -> Hard-DELETE
  SELECT finance.fn_create_pension('{"name":"__test_cp_c__","pension_type":"statutory"}'::jsonb) INTO v_res;
  v_p_c := (v_res->>'pension_id')::int;

  -- TEST 1: Hard-DELETE (mit RP)
  SELECT finance.fn_close_pension('{"pension_name":"__test_cp_a__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL close_pension [hard-delete A]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.pension WHERE id = v_p_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_pension [pension A noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_pension [rp A noch da]'; END IF;
  RAISE NOTICE 'PASS close_pension [Hard-DELETE mit RP]';

  -- TEST 2: Soft-Close
  SELECT finance.fn_close_pension('{"pension_name":"__test_cp_b__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed' THEN
    RAISE EXCEPTION 'FAIL close_pension [soft-close]: %', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.pension WHERE id = v_p_b;
  IF v_status IS DISTINCT FROM 'paused' THEN RAISE EXCEPTION 'FAIL close_pension [soft-close status]: %', v_status; END IF;
  SELECT status::text, valid_to INTO v_rp_status, v_valid_to FROM finance.recurring_payments WHERE id = v_rp_b;
  IF v_rp_status IS DISTINCT FROM 'paused' OR v_valid_to IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL close_pension [soft-close rp]: status=% valid_to=%', v_rp_status, v_valid_to; END IF;
  RAISE NOTICE 'PASS close_pension [Soft-Close: paused + RP beendet]';

  -- TEST 3: Hard-DELETE ohne RP
  SELECT finance.fn_close_pension('{"pension_name":"__test_cp_c__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL close_pension [hard-delete C ohne RP]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.pension WHERE id = v_p_c;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_pension [pension C noch da]'; END IF;
  RAISE NOTICE 'PASS close_pension [Hard-DELETE ohne RP]';

  -- TEST 4: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_close_pension('{"pension_name":"__test_cp_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL close_pension [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS close_pension [not-found -> ok:false]';
END $$;

ROLLBACK;
