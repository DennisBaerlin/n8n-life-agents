-- tests/db/finance/test_role_finance_goals_loans.sql
-- Rollen-Perspektive der Sparziel- und Kredit-Werkzeuge: alle fns laufen unter finance_rw (Write-Werkzeuge erst im
--   Probelauf ueber core.fn_dry_run, dann als echter Write; Lese-/Helfer-fns direkt). db_test laeuft als Superuser und
--   sieht fehlende Tabellen-/Sequenz-/EXECUTE-Rechte sonst nie. Fixture (Konten, Ziele, Kredite) entsteht als Superuser;
--   zwischen SET LOCAL ROLE und RESET ROLE steht nur der Aufruf der fn unter Test. Je fn ein DO-Block mit eigenen Namen.
BEGIN;

-- ===== fn_create_savings_goal (Ziel + Sparrate als recurring_payment) =====
DO $$
DECLARE
  r jsonb; v_giro int; v_pot int; v_goal int; v_rp int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__rl_csg_giro__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__rl_csg_pot__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_create_savings_goal(jsonb)'::regprocedure, jsonb_build_object(
         'name','__rl_csg_goal__','goal_type','vacation','target_amount',12000,'target_date','2028-01-01',
         'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date','2027-01-01'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'monthly_rate')::numeric IS DISTINCT FROM 923.08
     OR EXISTS (SELECT 1 FROM finance.savings_goals WHERE name = '__rl_csg_goal__') THEN
    RAISE EXCEPTION 'FAIL [create_savings_goal Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_savings_goal(jsonb_build_object(
         'name','__rl_csg_goal__','goal_type','vacation','target_amount',12000,'target_date','2028-01-01',
         'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date','2027-01-01'));
  RESET ROLE;
  v_goal := (r->>'goal_id')::int; v_rp := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'monthly_rate')::numeric IS DISTINCT FROM 923.08
     OR NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND target_amount = 12000
                      AND target_date = DATE '2028-01-01' AND status = 'active' AND recurring_payment_id = v_rp)
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND amount = -923.08
                      AND account_id = v_giro AND target_account_id = v_pot) THEN
    RAISE EXCEPTION 'FAIL [create_savings_goal Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_create_savings_goal (Rate 923.08 = 12000 / 13 Monate aufgerundet, Ziel + rp geschrieben)';
END $$;

-- ===== fn_set_savings_goal (Zielbetrag aendern -> Rate neu gerechnet) =====
DO $$
DECLARE
  r jsonb; v_giro int; v_pot int; v_goal int; v_rp int; v_new_rp int; v_rate numeric;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__rl_ssg_giro__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__rl_ssg_pot__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object(
         'name','__rl_ssg_goal__','target_amount',5000,'target_date','2028-12-31','monthly_savings_rate',200,
         'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date','2027-01-01'));
  v_goal := (r->>'goal_id')::int; v_rp := (r->>'recurring_payment_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_savings_goal(jsonb)'::regprocedure,
         jsonb_build_object('goal_id', v_goal, 'target_amount', 8000));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT target_amount FROM finance.savings_goals WHERE id = v_goal) <> 5000 THEN
    RAISE EXCEPTION 'FAIL [set_savings_goal Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'target_amount', 8000, 'notes', 'Rollen-Test'));
  RESET ROLE;
  v_rate := (r->>'new_monthly_rate')::numeric; v_new_rp := (r->>'recurring_payment_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_rate IS NULL OR v_rate <= 0
     OR NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal AND target_amount = 8000
                      AND notes = 'Rollen-Test' AND recurring_payment_id = v_new_rp)
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_new_rp) IS DISTINCT FROM -v_rate THEN
    RAISE EXCEPTION 'FAIL [set_savings_goal Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_set_savings_goal (Ziel 8000, Rate %)', v_rate;
END $$;

-- ===== fn_close_savings_goal (Fehlanlage ohne Buchung -> Hard-DELETE samt rp) =====
DO $$
DECLARE
  r jsonb; v_giro int; v_pot int; v_goal int; v_rp int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__rl_clg_giro__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__rl_clg_pot__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object(
         'name','__rl_clg_goal__','target_amount',5000,'target_date',(CURRENT_DATE + 365)::text,'monthly_savings_rate',100,
         'account_id',v_giro,'reserve_account_id',v_pot,'first_payment_date',CURRENT_DATE::text));
  v_goal := (r->>'goal_id')::int; v_rp := (r->>'recurring_payment_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_close_savings_goal(jsonb)'::regprocedure,
         jsonb_build_object('savings_goal_name', '__rl_clg_goal__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR NOT EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal) THEN
    RAISE EXCEPTION 'FAIL [close_savings_goal Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_close_savings_goal(jsonb_build_object('savings_goal_name', '__rl_clg_goal__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' IS DISTINCT FROM 'deleted'
     OR EXISTS (SELECT 1 FROM finance.savings_goals WHERE id = v_goal)
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [close_savings_goal Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_close_savings_goal (Ziel + rp geloescht)';
END $$;

-- ===== fn_resolve_savings_goal (Name -> id, 1 Treffer / 0 Treffer) =====
DO $$
DECLARE
  v_goal int; v_id int; v_hits int;
BEGIN
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rl_rsg_goal__', 3000, CURRENT_DATE + 400, 'active') RETURNING id INTO v_goal;

  SET LOCAL ROLE finance_rw;
  SELECT t.id, t.hit_count INTO v_id, v_hits FROM finance.fn_resolve_savings_goal('__rl_rsg_goal__', TRUE) AS t;
  RESET ROLE;
  IF v_hits IS DISTINCT FROM 1 OR v_id IS DISTINCT FROM v_goal THEN
    RAISE EXCEPTION 'FAIL [resolve_savings_goal 1 Treffer finance_rw]: id=% hits=% (erwartet %)', v_id, v_hits, v_goal; END IF;

  SET LOCAL ROLE finance_rw;
  SELECT t.id, t.hit_count INTO v_id, v_hits FROM finance.fn_resolve_savings_goal('__rl_rsg_none__', TRUE) AS t;
  RESET ROLE;
  IF v_hits IS DISTINCT FROM 0 OR v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [resolve_savings_goal 0 Treffer finance_rw]: id=% hits=%', v_id, v_hits; END IF;
  RAISE NOTICE 'PASS finance_rw fn_resolve_savings_goal';
END $$;

-- ===== fn_book_savings_goal_transfer (deposit Giro -> Topf, getaggtes Reserve-Bein) =====
DO $$
DECLARE
  r jsonb; v_giro int; v_pot int; v_goal int; v_cur numeric;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__rl_bgt_giro__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  v_pot  := (finance.fn_create_account('{"name":"__rl_bgt_pot__","account_type":"cash","account_holder":"Erika"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object(
         'name','__rl_bgt_goal__','target_amount',5000,'target_date',(CURRENT_DATE + 365)::text,'monthly_savings_rate',100,
         'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1,'first_payment_date',CURRENT_DATE::text));
  v_goal := (r->>'goal_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_savings_goal_transfer(jsonb)'::regprocedure, jsonb_build_object(
         'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_pot,'amount',500,
         'direction','deposit','transaction_date',CURRENT_DATE::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.transactions WHERE savings_goal_id = v_goal) THEN
    RAISE EXCEPTION 'FAIL [book_savings_goal_transfer Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_savings_goal_transfer(jsonb_build_object(
         'savings_goal_id',v_goal,'from_account_id',v_giro,'to_account_id',v_pot,'amount',500,
         'direction','deposit','transaction_date',CURRENT_DATE::text));
  RESET ROLE;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_cur IS DISTINCT FROM 500
     OR finance.fn_get_balance(v_giro) IS DISTINCT FROM -500 OR finance.fn_get_balance(v_pot) IS DISTINCT FROM 500
     OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE savings_goal_id = v_goal AND account_id = v_pot AND amount = 500) THEN
    RAISE EXCEPTION 'FAIL [book_savings_goal_transfer Write finance_rw]: % (Fortschritt %)', r, v_cur; END IF;
  RAISE NOTICE 'PASS finance_rw fn_book_savings_goal_transfer (Fortschritt 500)';
END $$;

-- ===== fn_book_savings_reservation (Zuordnung 3000 von 5000 auf einem P2P-Konto, Journal-Zeile) =====
DO $$
DECLARE
  r jsonb; v_p2p int; v_goal int;
BEGIN
  v_p2p := (finance.fn_create_account('{"name":"__rl_bsr_p2p__","account_type":"p2p","opening_balance":5000}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__rl_bsr_goal__', 8000, CURRENT_DATE + 400, 'active') RETURNING id INTO v_goal;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_savings_reservation(jsonb)'::regprocedure,
         jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_p2p, 'amount', 3000));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal) THEN
    RAISE EXCEPTION 'FAIL [book_savings_reservation Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_savings_reservation(jsonb_build_object('savings_goal_id', v_goal, 'account_id', v_p2p, 'amount', 3000));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'reserved')::numeric IS DISTINCT FROM 3000
     OR (r->>'delta')::numeric IS DISTINCT FROM 3000 OR (r->>'free_balance')::numeric IS DISTINCT FROM 2000
     OR (SELECT sum(delta_native) FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal AND account_id = v_p2p)
          IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL [book_savings_reservation Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_book_savings_reservation (reserviert 3000, frei 2000)';
END $$;

-- ===== fn_goal_pot_account_types / fn_goal_earmark_account_types (Allowlisten der Kontotypen) =====
DO $$
DECLARE
  v_pot finance.account_type[]; v_ear finance.account_type[];
BEGIN
  SET LOCAL ROLE finance_rw;
  v_pot := finance.fn_goal_pot_account_types();
  RESET ROLE;
  IF cardinality(v_pot) <> 3 OR NOT (v_pot @> ARRAY['cash','fixed_deposit','p2p']::finance.account_type[]) THEN
    RAISE EXCEPTION 'FAIL [goal_pot_account_types finance_rw]: %', v_pot; END IF;

  SET LOCAL ROLE finance_rw;
  v_ear := finance.fn_goal_earmark_account_types();
  RESET ROLE;
  -- Topf-Typen + beide Depots, nie Kredit
  IF cardinality(v_ear) <> 5 OR NOT (v_ear @> (v_pot || ARRAY['stocks_depot','crypto_depot']::finance.account_type[]))
     OR 'loan' = ANY (v_ear::text[]) THEN
    RAISE EXCEPTION 'FAIL [goal_earmark_account_types finance_rw]: %', v_ear; END IF;
  RAISE NOTICE 'PASS finance_rw fn_goal_pot_account_types + fn_goal_earmark_account_types';
END $$;

-- ===== fn_create_loan (Kredit + Kreditkonto + Raten-rp + Auszahlungsbeine) =====
DO $$
DECLARE
  r jsonb; v_debit int; v_loan int; v_lacc int; v_rp int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_cl_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_create_loan(jsonb)'::regprocedure, jsonb_build_object(
         'name','__rl_cl_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR EXISTS (SELECT 1 FROM finance.loans WHERE name = '__rl_cl_loan__') THEN
    RAISE EXCEPTION 'FAIL [create_loan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_cl_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));
  RESET ROLE;
  v_loan := (r->>'loan_id')::int; v_lacc := (r->>'loan_account_id')::int; v_rp := (r->>'recurring_payment_id')::int;
  IF v_loan IS NULL OR v_lacc IS NULL OR v_rp IS NULL
     OR NOT EXISTS (SELECT 1 FROM finance.loans WHERE id = v_loan AND original_amount = 10000 AND interest_rate = 3 AND status = 'active')
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp AND amount = -500 AND account_id = v_debit)
     OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -10000 THEN
    RAISE EXCEPTION 'FAIL [create_loan Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_create_loan (Restschuld 10000, Rate 500)';
END $$;

-- ===== fn_set_loan (Zinssatz, dann Rate ueber die Raten-Kette) =====
DO $$
DECLARE
  r jsonb; v_debit int; v_loan int; v_rp int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_sl_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_sl_loan__','lender','Buchenbank','borrower','Erika','original_amount',100000,
         'disbursement_date','2026-01-01','interest_rate',3.0,'monthly_annuity',1200,'schedule_day_of_month',1,
         'first_payment_date','2026-02-01','debit_account_id',v_debit));
  v_loan := (r->>'loan_id')::int; v_rp := (r->>'recurring_payment_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_set_loan(jsonb)'::regprocedure, jsonb_build_object('loan_id', v_loan, 'interest_rate', 3.5));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT interest_rate FROM finance.loans WHERE id = v_loan) <> 3.0 THEN
    RAISE EXCEPTION 'FAIL [set_loan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', 3.5));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT interest_rate FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM 3.5
     OR (r->>'recurring_payment_id')::int IS DISTINCT FROM v_rp THEN
    RAISE EXCEPTION 'FAIL [set_loan Zinssatz finance_rw]: %', r; END IF;

  -- Rate 1200 -> 1500: offene Termine seit Februar -> Split ab dem naechsten Termin; altes Glied behaelt 1200 (Historie)
  SET LOCAL ROLE finance_rw;
  r := finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'monthly_annuity', 1500));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR (r->>'split')::boolean IS DISTINCT FROM true OR (r->>'previous_id')::int IS DISTINCT FROM v_rp
     OR (SELECT amount FROM finance.recurring_payments WHERE id = v_rp) IS DISTINCT FROM -1200
     OR (SELECT amount FROM finance.recurring_payments WHERE id = (r->>'recurring_payment_id')::int) IS DISTINCT FROM -1500 THEN
    RAISE EXCEPTION 'FAIL [set_loan Rate finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_set_loan (Zins 3.5, Rate 1500)';
END $$;

-- ===== fn_delete_loan (Fehlanlage ohne gebuchte Rate -> Hard-DELETE samt Konto und rp) =====
DO $$
DECLARE
  r jsonb; v_debit int; v_loan int; v_lacc int; v_rp int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_dl_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_dl_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));
  v_loan := (r->>'loan_id')::int; v_lacc := (r->>'loan_account_id')::int; v_rp := (r->>'recurring_payment_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_delete_loan(jsonb)'::regprocedure, jsonb_build_object('loan_name', '__rl_dl_loan__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR NOT EXISTS (SELECT 1 FROM finance.loans WHERE id = v_loan) THEN
    RAISE EXCEPTION 'FAIL [delete_loan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_delete_loan(jsonb_build_object('loan_name', '__rl_dl_loan__'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'action' IS DISTINCT FROM 'deleted'
     OR EXISTS (SELECT 1 FROM finance.loans WHERE id = v_loan)
     OR EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_lacc)
     OR EXISTS (SELECT 1 FROM finance.recurring_payments WHERE id = v_rp)
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE loan_id = v_loan)
     OR NOT EXISTS (SELECT 1 FROM finance.accounts WHERE id = v_debit) THEN
    RAISE EXCEPTION 'FAIL [delete_loan Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_delete_loan (Kredit, Konto, rp, Buchungen weg; Giro bleibt)';
END $$;

-- ===== fn_resolve_loan (Name -> Kredit-/Konto-ids, 1 Treffer / 0 Treffer) =====
DO $$
DECLARE
  v_debit int; v_res jsonb; v_loan int; v_lacc int; v_deb int; v_rate numeric; v_hits int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_rl_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_res := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_rl_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));

  SET LOCAL ROLE finance_rw;
  SELECT t.loan_id, t.loan_account_id, t.debit_account_id, t.monthly_annuity, t.hit_count
    INTO v_loan, v_lacc, v_deb, v_rate, v_hits FROM finance.fn_resolve_loan('__rl_rl_loan__') AS t;
  RESET ROLE;
  IF v_hits IS DISTINCT FROM 1 OR v_loan IS DISTINCT FROM (v_res->>'loan_id')::int
     OR v_lacc IS DISTINCT FROM (v_res->>'loan_account_id')::int OR v_deb IS DISTINCT FROM v_debit OR v_rate IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL [resolve_loan 1 Treffer finance_rw]: loan=% lacc=% debit=% rate=% hits=%', v_loan, v_lacc, v_deb, v_rate, v_hits; END IF;

  SET LOCAL ROLE finance_rw;
  SELECT t.hit_count INTO v_hits FROM finance.fn_resolve_loan('__rl_rl_none__') AS t;
  RESET ROLE;
  IF v_hits IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [resolve_loan 0 Treffer finance_rw]: hits=%', v_hits; END IF;
  RAISE NOTICE 'PASS finance_rw fn_resolve_loan';
END $$;

-- ===== fn_settle_loan (Abloesung zur Restschuld -> Saldo 0, paid_off, Giro belastet) =====
DO $$
DECLARE
  r jsonb; v_debit int; v_loan int; v_lacc int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_stl_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_stl_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));
  v_loan := (r->>'loan_id')::int; v_lacc := (r->>'loan_account_id')::int;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_settle_loan(jsonb)'::regprocedure, jsonb_build_object(
         'loan_name','__rl_stl_loan__','debit_account_id',v_debit,'settlement_date',CURRENT_DATE::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (SELECT status::text FROM finance.loans WHERE id = v_loan) <> 'active' THEN
    RAISE EXCEPTION 'FAIL [settle_loan Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_settle_loan(jsonb_build_object(
         'loan_name','__rl_stl_loan__','debit_account_id',v_debit,'settlement_date',CURRENT_DATE::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'remaining_debt')::numeric IS DISTINCT FROM 10000
     OR (SELECT status::text FROM finance.loans WHERE id = v_loan) IS DISTINCT FROM 'paid_off'
     OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM 0 OR finance.fn_get_balance(v_debit) IS DISTINCT FROM -10000 THEN
    RAISE EXCEPTION 'FAIL [settle_loan Write finance_rw]: %', r; END IF;
  RAISE NOTICE 'PASS finance_rw fn_settle_loan (Restschuld 10000 getilgt, paid_off)';
END $$;

-- ===== fn_get_loan_payment_split + fn_book_loan_payment (Rate 500: Zins 25, Tilgung 475) =====
DO $$
DECLARE
  r jsonb; v_debit int; v_loan int; v_lacc int;
BEGIN
  v_debit := (finance.fn_create_account('{"name":"__rl_blp_debit__","account_type":"cash","account_holder":"Erika","currency":"EUR"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object(
         'name','__rl_blp_loan__','lender','Buchenbank','borrower','Erika','original_amount',10000,'current_balance',10000,
         'disbursement_date',CURRENT_DATE::text,'interest_rate',3,'monthly_annuity',500,'schedule_day_of_month',1,
         'first_payment_date',CURRENT_DATE::text,'debit_account_id',v_debit));
  v_loan := (r->>'loan_id')::int; v_lacc := (r->>'loan_account_id')::int;

  -- Vorschau (read-only): 10000 * 3 % / 12 = 25 Zins, 475 Tilgung
  SET LOCAL ROLE finance_rw;
  r := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_loan, 'payment_amount', 500));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'remaining_debt')::numeric IS DISTINCT FROM 10000
     OR (r->>'interest_portion')::numeric IS DISTINCT FROM 25 OR (r->>'principal_amount')::numeric IS DISTINCT FROM 475
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE loan_id = v_loan AND category IN ('principal', 'loan_payment')) THEN
    RAISE EXCEPTION 'FAIL [get_loan_payment_split finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := core.fn_dry_run('finance.fn_book_loan_payment(jsonb)'::regprocedure, jsonb_build_object(
         'loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_debit,'payment_amount',500,'payment_date',CURRENT_DATE::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_debit) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [book_loan_payment Probelauf finance_rw]: %', r; END IF;

  SET LOCAL ROLE finance_rw;
  r := finance.fn_book_loan_payment(jsonb_build_object(
         'loan_id',v_loan,'loan_account_id',v_lacc,'debit_account_id',v_debit,'payment_amount',500,'payment_date',CURRENT_DATE::text));
  RESET ROLE;
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'interest_portion')::numeric IS DISTINCT FROM 25
     OR (r->>'principal_amount')::numeric IS DISTINCT FROM 475
     OR finance.fn_get_balance(v_debit) IS DISTINCT FROM -500 OR finance.fn_get_balance(v_lacc) IS DISTINCT FROM -9525 THEN
    RAISE EXCEPTION 'FAIL [book_loan_payment Write finance_rw]: % (Giro %, Kredit %)', r,
      finance.fn_get_balance(v_debit), finance.fn_get_balance(v_lacc); END IF;
  RAISE NOTICE 'PASS finance_rw fn_get_loan_payment_split + fn_book_loan_payment (Zins 25, Tilgung 475)';
END $$;

ROLLBACK;
