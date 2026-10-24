-- tests/db/finance/test_fn_create_recurring_payment.sql
-- Testet fn_create_recurring_payment: Vorzeichen aus direction, monthly_equivalent, Guards.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_acct_id INT;
  v_rp_id   INT;
  v_amount  NUMERIC;
BEGIN

  SELECT finance.fn_create_account(
    '{"name":"__test_recpay_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- TEST 1: Einnahme (income) -> +amount, monthly_equivalent
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Gehalt','account_id',v_acct_id,'direction','income','amount',3000,
    'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income]: erwartet ok=true, got %', v_result;
  END IF;
  IF (v_result->>'monthly_equivalent')::numeric IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income me]: erwartet 3000, got %', v_result;
  END IF;
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  SELECT amount INTO v_amount FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM 3000 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [income sign]: erwartet +3000, got %', v_amount;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [income +3000]';

  -- TEST 2: Ausgabe (expense) -> -amount
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Miete','account_id',v_acct_id,'direction','expense','amount',1500,
    'schedule_unit','month','schedule_day_of_month',1,'first_payment_date','2026-01-01'
  )) INTO v_result;
  v_rp_id := (v_result->>'recurring_payment_id')::int;
  SELECT amount INTO v_amount FROM finance.recurring_payments WHERE id = v_rp_id;
  IF v_amount IS DISTINCT FROM -1500 THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [expense sign]: erwartet -1500, got %', v_amount;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [expense -1500]';

  -- TEST 3: amount <= 0 -> {ok:false}
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Null','account_id',v_acct_id,'direction','income','amount',0,
    'schedule_unit','month','first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [amount<=0 -> ok:false]';

  -- TEST 4: ungueltige direction -> {ok:false}
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','Quatsch','account_id',v_acct_id,'direction','sideways','amount',100,
    'schedule_unit','month','first_payment_date','2026-01-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_recurring_payment [bad direction]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_recurring_payment [bad direction -> ok:false]';

END $$;

-- TEST 5 (Phase L WS-3): Cashflow-Sofort-Hinweis (Event-Fold). Die fn liest monthly_cashflow_summary (GLOBALE
-- Single-Row-View) -> SAVEPOINT + bestehende rp (Tests 1-4 + evtl. Seed) neutralisieren, kontrollierten Cashflow
-- setzen, danach ROLLBACK TO SAVEPOINT. (5a) Einnahmen-Anlage -> net>0 -> KEINE Note (Kontrolle). (5b) Ausgabe >
-- Einnahmen -> net<0 -> cashflow_coverage-Note im {ok:true}-Return.
SAVEPOINT crp_fold;
UPDATE finance.recurring_payments SET status = 'paused';   -- nur im Savepoint; FK-frei
DO $$
DECLARE
  v_res jsonb; v_acct int;
BEGIN
  SELECT finance.fn_create_account('{"name":"__crp_fold_acct__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_res;
  v_acct := (v_res->>'account_id')::int;

  -- (5a) Einkommen +2000 (nur diese rp aktiv) -> net +2000 -> KEINE Note
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__crp_fold_inc__','account_id',v_acct,'direction','income','amount',2000,
    'schedule_unit','month','first_payment_date',current_date::text)) INTO v_res;
  IF v_res ? 'cashflow_coverage' THEN
    RAISE EXCEPTION 'FAIL [5a]: cashflow_coverage-Fold trotz gesundem net (+2000), got %', v_res; END IF;
  RAISE NOTICE 'PASS [5a WS-3: Einnahme -> net>0 -> kein Fold]';

  -- (5b) Ausgabe -3000 -> net = 2000 - 3000 = -1000 -> cashflow_coverage-Note
  SELECT finance.fn_create_recurring_payment(jsonb_build_object(
    'name','__crp_fold_exp__','account_id',v_acct,'direction','expense','amount',3000,
    'schedule_unit','month','first_payment_date',current_date::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [5b setup]: %', v_res; END IF;
  IF NOT (v_res ? 'cashflow_coverage') OR COALESCE(v_res->'cashflow_coverage'->>'note','') = '' THEN
    RAISE EXCEPTION 'FAIL [5b]: kein cashflow_coverage-Fold mit note bei net<0, got %', v_res; END IF;
  RAISE NOTICE 'PASS [5b WS-3: Ausgabe kippt net<0 -> cashflow_coverage-Fold im Return]';
END $$;
ROLLBACK TO SAVEPOINT crp_fold;

-- TEST 6 (DB-ist-das-Gesetz S6): Namenssperre nur in der oeffentlichen create-fn, Praedikat = active_recurring_payments.
--   (a) laufende, freistehende Zahlung gleichen Namens (ohne Gross-/Kleinschreibung) -> ok:false duplicate_name + candidates
--   (b) gleichnamige Zahlung einer Entitaet (Versicherung) blockiert nicht -> ok:true + Hinweis-Zeile auf der Karte
DO $$
DECLARE v_acct int; v_r jsonb;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__test_rpdup_acct__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__RPDUP Streaming__','account_id',v_acct,
           'direction','expense','amount',10,'schedule_unit','month','first_payment_date','2026-01-05'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 Setup]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name','__rpdup streaming__','account_id',v_acct,
           'direction','expense','amount',12,'schedule_unit','month','first_payment_date','2026-02-05'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'duplicate_name'
     OR jsonb_array_length(v_r->'candidates') <> 1 THEN
    RAISE EXCEPTION 'FAIL [6a Namens-Dublette laufend]: %', v_r; END IF;

  v_r := finance.fn_create_insurance(jsonb_build_object('name','__RPDUP Hausrat__','annual_premium',120,
           'first_payment_date','2026-01-15','debit_account_id',v_acct));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6 Setup Versicherung]: %', v_r; END IF;
  v_r := finance.fn_create_recurring_payment(jsonb_build_object('name',
           (SELECT rp.name FROM finance.recurring_payments rp JOIN finance.insurances i ON i.recurring_payment_id = rp.id
             WHERE i.name = '__RPDUP Hausrat__'),
           'account_id',v_acct,'direction','expense','amount',10,'schedule_unit','year','first_payment_date','2026-03-01'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_r->'card_lines') l
                    WHERE l->>'kind' = 'note' AND l->>'value' = 'finance.note.similar_recurring_payment') THEN
    RAISE EXCEPTION 'FAIL [6b Entitaets-Zahlung gleichen Namens -> nur Hinweis]: %', v_r; END IF;
  RAISE NOTICE 'PASS [6 Namenssperre: laufend frei -> ok:false, Entitaets-Zahlung -> Karten-Hinweis]';
END $$;

ROLLBACK;
