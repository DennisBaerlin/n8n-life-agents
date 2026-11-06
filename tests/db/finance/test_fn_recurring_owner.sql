-- tests/db/finance/test_fn_recurring_owner.sql
-- fn_recurring_owner erkennt den Besitzer ueber den KOPF der Vorgaenger-Kette (WP2): nach einer Ratenaenderung mit
-- kuenftigem Stichtag laeuft das alte Glied noch -- es darf weder als freistehende Zahlung aenderbar (set_recurring_payment)
-- noch loeschbar sein. Freistehende Zahlungen bleiben NULL.
BEGIN;

DO $$
DECLARE v_giro INT; v_loan JSONB; v_old INT; v_res JSONB; v_free INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_ro_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_loan := finance.fn_create_loan(jsonb_build_object('name','__test_ro_loan__','lender','Bank','current_balance',10000,
    'interest_rate',2,'monthly_annuity',300,'first_payment_date',(CURRENT_DATE - 20)::text,'debit_account_id',v_giro));
  v_old := (v_loan->>'recurring_payment_id')::int;
  -- Rate ab einem kuenftigen Stichtag -> neues Glied, das alte laeuft bis dahin weiter
  v_res := finance.fn_set_loan(jsonb_build_object('loan_id', (v_loan->>'loan_id')::int, 'monthly_annuity', 350,
    'effective_from', (CURRENT_DATE + 40)::text));
  IF (v_res->>'split')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL split: %', v_res; END IF;
  IF finance.fn_recurring_owner(v_old) IS DISTINCT FROM 'loan' THEN
    RAISE EXCEPTION 'FAIL [owner Vorgaenger]: %', finance.fn_recurring_owner(v_old); END IF;
  v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id', v_old, 'name', 'umbenannt'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [set_recurring_payment Vorgaenger]: ok:false erwartet, got %', v_res; END IF;
  v_free := finance.fn_add_recurring_payment(v_giro, -20, '__test_ro_abo__', 1::smallint, 'month'::finance.schedule_unit,
                                             1::smallint, CURRENT_DATE, CURRENT_DATE, NULL, NULL, NULL);
  IF finance.fn_recurring_owner(v_free) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [frei]'; END IF;
  RAISE NOTICE 'PASS fn_recurring_owner (Vorgaenger-Glied gehoert dem Kredit, set_recurring_payment lehnt ab, frei = NULL)';
END $$;

ROLLBACK;
