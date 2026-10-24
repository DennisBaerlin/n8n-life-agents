-- tests/db/finance/test_fn_sell_real_estate.sql
-- Testet fn_sell_real_estate: Verkauf buchen (+Erloes, status=sold), Allow+Hinweis bei offenem
-- Kredit (linked_loans mit Name+Restschuld), Guards (sale_price<=0 / bereits verkauft).
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_acct   INT;
  v_debit  INT;
  v_re     INT;
  v_re2    INT;
  v_re3    INT;
  v_loanacc INT;
  v_bal    NUMERIC;
  v_status TEXT;
  v_cv     NUMERIC;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_sre_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_acct;
  SELECT (finance.fn_create_account('{"name":"__test_sre_debit__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_debit;

  -- Immobilie A: ohne Kredit
  SELECT (finance.fn_create_real_estate('{"name":"__test_sre_clean__","current_value":300000,"owner":"T"}'::jsonb)->>'real_estate_id')::int INTO v_re;

  -- Immobilie B: mit aktivem verknuepftem Kredit (Restschuld 120000)
  SELECT (finance.fn_create_real_estate('{"name":"__test_sre_loaned__","current_value":300000,"owner":"T"}'::jsonb)->>'real_estate_id')::int INTO v_re2;
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_sre_loan__','lender','TB','borrower','T','original_amount','120000','current_balance','120000',
    'disbursement_date',CURRENT_DATE::text,'interest_rate','3','monthly_annuity','600',
    'schedule_day_of_month','1','first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit,
    'real_estate_id', v_re2)) INTO v_res;

  -- TEST 1: Verkauf ohne Kredit -> +Erloes, status=sold, linked_loan_count=0
  SELECT finance.fn_sell_real_estate(jsonb_build_object(
    'real_estate_name','__test_sre_clean__','proceeds_account_id',v_acct,'sale_date',CURRENT_DATE::text,'sale_price','320000')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [clean]: erwartet ok=true, got %', v_res; END IF;
  IF (v_res->>'linked_loan_count')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [clean linked_loan_count]: erwartet 0, got %', v_res->>'linked_loan_count'; END IF;
  SELECT status::text, current_value INTO v_status, v_cv FROM finance.real_estate WHERE id = v_re;
  IF v_status IS DISTINCT FROM 'sold' OR v_cv IS DISTINCT FROM 320000 THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [clean status/value]: got %/%', v_status, v_cv; END IF;
  SELECT finance.fn_get_balance(v_acct) INTO v_bal;
  IF v_bal IS DISTINCT FROM 320000 THEN RAISE EXCEPTION 'FAIL sell_real_estate [clean erloes]: erwartet 320000, got %', v_bal; END IF;
  RAISE NOTICE 'PASS sell_real_estate [clean: sold, +320000, keine Kredite]';

  -- TEST 2: Verkauf mit offenem Kredit -> ok:true + linked_loans (Name + Restschuld) + note
  SELECT finance.fn_sell_real_estate(jsonb_build_object(
    'real_estate_name','__test_sre_loaned__','proceeds_account_id',v_acct,'sale_date',CURRENT_DATE::text,'sale_price','350000')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [loaned]: erwartet ok=true, got %', v_res; END IF;
  IF (v_res->>'linked_loan_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [loaned count]: erwartet 1, got %', v_res->>'linked_loan_count'; END IF;
  IF NOT (v_res->'linked_loans'->0->>'name' = '__test_sre_loan__'
          AND (v_res->'linked_loans'->0->>'remaining_debt')::numeric = 120000) THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [loaned linked_loans]: erwartet name+remaining_debt=120000, got %', v_res->'linked_loans'; END IF;
  IF v_res->>'note' IS NULL THEN RAISE EXCEPTION 'FAIL sell_real_estate [loaned note fehlt]: %', v_res; END IF;
  RAISE NOTICE 'PASS sell_real_estate [loaned: allow+note, linked_loans mit Restschuld]';

  -- TEST 3: sale_price <= 0 -> {ok:false}
  SELECT (finance.fn_create_real_estate('{"name":"__test_sre_neg__","current_value":100000,"owner":"T"}'::jsonb)->>'real_estate_id')::int INTO v_re3;
  SELECT finance.fn_sell_real_estate(jsonb_build_object(
    'real_estate_name','__test_sre_neg__','proceeds_account_id',v_acct,'sale_date',CURRENT_DATE::text,'sale_price','0')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [price<=0]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS sell_real_estate [price<=0: ok=false]';

  -- TEST 4: bereits verkauft -> {ok:false}
  SELECT finance.fn_sell_real_estate(jsonb_build_object(
    'real_estate_name','__test_sre_clean__','proceeds_account_id',v_acct,'sale_date',CURRENT_DATE::text,'sale_price','100000')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [already-sold]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS sell_real_estate [already-sold: ok=false]';

  -- TEST 5: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_sell_real_estate(jsonb_build_object('real_estate_name','__test_sre_missing__','proceeds_account_id',v_acct,'sale_date',CURRENT_DATE::text,'sale_price','100000')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS sell_real_estate [not-found -> ok:false]';
END $$;

ROLLBACK;
