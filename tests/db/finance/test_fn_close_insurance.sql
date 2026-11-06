-- tests/db/finance/test_fn_close_insurance.sql
-- Testet fn_close_insurance: Hard-DELETE (keine Buchungen), Soft-Close (Buchungen vorhanden), not-found und (WP2)
-- Ketten-Festigkeit nach einer Beitragsaenderung: Buchungen ueber die ganze Kette, Loeschen/Beenden aller Glieder.
BEGIN;

DO $$
DECLARE
  v_res        JSONB;
  v_acct       INT;
  v_ins_a      INT; v_rp_a INT;
  v_ins_b      INT; v_rp_b INT;
  v_cnt        INT;
  v_status     TEXT; v_valid_to DATE; v_rp_status TEXT;
BEGIN
  -- Setup: Abbuchungskonto
  SELECT finance.fn_create_account('{"name":"__test_ci_acct__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- Insurance A: keine Buchungen -> Hard-DELETE-Kandidat
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ci_a__','policyholder','Erika','annual_premium',600,
    'schedule_unit','month','valid_from',CURRENT_DATE::text,'first_payment_date',CURRENT_DATE::text,
    'debit_account_id',v_acct,'recurring_amount',-50)) INTO v_res;
  v_ins_a := (v_res->>'insurance_id')::int; v_rp_a := (v_res->>'recurring_payment_id')::int;

  -- Insurance B: eine Buchung auf der RP -> Soft-Close-Kandidat
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ci_b__','policyholder','Erika','annual_premium',1200,
    'schedule_unit','month','valid_from',CURRENT_DATE::text,'first_payment_date',CURRENT_DATE::text,
    'debit_account_id',v_acct,'recurring_amount',-100)) INTO v_res;
  v_ins_b := (v_res->>'insurance_id')::int; v_rp_b := (v_res->>'recurring_payment_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -100, CURRENT_DATE - 30, 'other', v_rp_b, 'Test-Praemie');

  -- TEST 1: Hard-DELETE
  SELECT finance.fn_close_insurance('{"insurance_name":"__test_ci_a__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted'
     OR (v_res->>'tx_count')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL close_insurance [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.insurances WHERE id = v_ins_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_insurance [ins A noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.recurring_payments WHERE id = v_rp_a;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL close_insurance [rp A noch da]'; END IF;
  RAISE NOTICE 'PASS close_insurance [Hard-DELETE: Police + RP entfernt]';

  -- TEST 2: Soft-Close
  SELECT finance.fn_close_insurance('{"insurance_name":"__test_ci_b__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'closed'
     OR (v_res->>'tx_count')::int < 1 THEN
    RAISE EXCEPTION 'FAIL close_insurance [soft-close]: %', v_res; END IF;
  SELECT status::text INTO v_status FROM finance.insurances WHERE id = v_ins_b;
  IF v_status IS DISTINCT FROM 'cancelled' THEN
    RAISE EXCEPTION 'FAIL close_insurance [soft-close ins]: status=%', v_status; END IF;
  SELECT status::text, valid_to INTO v_rp_status, v_valid_to FROM finance.recurring_payments WHERE id = v_rp_b;
  IF v_rp_status IS DISTINCT FROM 'paused' OR v_valid_to IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL close_insurance [soft-close rp]: status=% valid_to=%', v_rp_status, v_valid_to; END IF;
  RAISE NOTICE 'PASS close_insurance [Soft-Close: cancelled + RP paused, Historie bleibt]';

  -- TEST 2b (WP2): Beitragsaenderung mit kuenftigem Stichtag -> zwei Glieder; Buchung nur am ALTEN Glied ->
  --   Soft-Close (nicht Hard-DELETE) und beide Glieder enden; ohne Buchung -> beide Glieder geloescht.
  DECLARE v_ins_c INT; v_rp_c INT; v_ins_d INT; v_rp_d INT;
  BEGIN
    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ci_c__','premium_amount',20,
      'schedule_unit','month','first_payment_date',(CURRENT_DATE - 40)::text,'debit_account_id',v_acct)) INTO v_res;
    v_ins_c := (v_res->>'insurance_id')::int; v_rp_c := (v_res->>'recurring_payment_id')::int;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date, description)
    VALUES (v_acct, -20, CURRENT_DATE - 40, 'other', v_rp_c, CURRENT_DATE - 40, 'Test-Praemie');
    v_res := finance.fn_set_insurance(jsonb_build_object('insurance_id', v_ins_c, 'premium_amount', 25,
      'effective_from', (CURRENT_DATE + 30)::text));
    IF (v_res->>'split')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL split: %', v_res; END IF;
    SELECT finance.fn_close_insurance('{"insurance_name":"__test_ci_c__"}'::jsonb) INTO v_res;
    IF v_res->>'action' IS DISTINCT FROM 'closed' OR EXISTS (
         SELECT 1 FROM finance.recurring_payments WHERE id IN (SELECT finance.fn_recurring_lineage(v_rp_c))
            AND (status <> 'paused' OR valid_to IS NULL OR valid_to > GREATEST(valid_from, CURRENT_DATE))) THEN
      RAISE EXCEPTION 'FAIL close_insurance [Kette soft]: %', v_res; END IF;

    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ci_d__','premium_amount',20,
      'schedule_unit','month','first_payment_date',(CURRENT_DATE - 40)::text,'debit_account_id',v_acct)) INTO v_res;
    v_ins_d := (v_res->>'insurance_id')::int; v_rp_d := (v_res->>'recurring_payment_id')::int;
    PERFORM finance.fn_set_insurance(jsonb_build_object('insurance_id', v_ins_d, 'premium_amount', 25,
      'effective_from', (CURRENT_DATE + 30)::text));
    SELECT finance.fn_close_insurance('{"insurance_name":"__test_ci_d__"}'::jsonb) INTO v_res;
    IF v_res->>'action' IS DISTINCT FROM 'deleted'
       OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp_d OR predecessor_id = v_rp_d) THEN
      RAISE EXCEPTION 'FAIL close_insurance [Kette hard]: %', v_res; END IF;
  END;
  RAISE NOTICE 'PASS close_insurance [Kette: Buchung am alten Glied -> Soft-Close aller Glieder; ohne Buchung -> ganze Kette geloescht]';

  -- TEST 3: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_close_insurance('{"insurance_name":"__test_ci_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL close_insurance [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS close_insurance [not-found -> ok:false]';
END $$;

ROLLBACK;
