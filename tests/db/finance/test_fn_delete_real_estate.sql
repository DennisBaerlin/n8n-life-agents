-- tests/db/finance/test_fn_delete_real_estate.sql
-- Testet fn_delete_real_estate: Hard-DELETE (keine Kredite), Guard (von Kredit referenziert), not-found
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_re_a    INT;
  v_re_b    INT;
  v_loanacc INT;
  v_cnt     INT;
BEGIN
  -- RE A: keine Kredite -> loeschbar
  SELECT finance.fn_create_real_estate('{"name":"__test_dre_a__","current_value":300000,"owner":"Erika"}'::jsonb) INTO v_res;
  v_re_a := (v_res->>'real_estate_id')::int;

  -- RE B: von einem Kredit referenziert -> Guard {ok:false}
  SELECT finance.fn_create_real_estate('{"name":"__test_dre_b__","current_value":250000,"owner":"Erika"}'::jsonb) INTO v_res;
  v_re_b := (v_res->>'real_estate_id')::int;
  -- loan-Konto direkt (fn_create_account lehnt loan ab; Kredit-Konten legt nur fn_create_loan an)
  WITH i AS (INSERT INTO finance.accounts (name, account_type) VALUES ('__test_dre_loanacc__', 'loan') RETURNING id)
    SELECT jsonb_build_object('account_id', id) INTO v_res FROM i;
  v_loanacc := (v_res->>'account_id')::int;
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate,
      loan_account_id, real_estate_id, status)
  VALUES ('__test_dre_loan__', 200000, CURRENT_DATE, 3.0, v_loanacc, v_re_b, 'paused');

  -- TEST 1: Hard-DELETE
  SELECT finance.fn_delete_real_estate('{"real_estate_name":"__test_dre_a__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL delete_real_estate [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.real_estate WHERE id = v_re_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_real_estate [RE A noch da]'; END IF;
  RAISE NOTICE 'PASS delete_real_estate [Hard-DELETE]';

  -- TEST 2: Guard (von Kredit referenziert) -> {ok:false}, nichts geloescht
  SELECT finance.fn_delete_real_estate('{"real_estate_name":"__test_dre_b__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'loan_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL delete_real_estate [loan-guard]: erwartet ok=false loan_count=1, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.real_estate WHERE id = v_re_b;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_real_estate [RE B faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_real_estate [loan-guard: ok=false, RE bleibt]';

  -- TEST 3: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_delete_real_estate('{"real_estate_name":"__test_dre_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL delete_real_estate [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS delete_real_estate [not-found -> ok:false]';
END $$;

ROLLBACK;
