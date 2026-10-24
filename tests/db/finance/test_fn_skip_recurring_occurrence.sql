-- tests/db/finance/test_fn_skip_recurring_occurrence.sql
-- Testet das Ueberspringen: Skip-Zeile angelegt, idempotent (ON CONFLICT).
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_rp     INT;
  v_due    DATE := '2026-06-01';
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_skiprec_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  v_rp := finance.fn_add_recurring_payment(v_acct, -50, 'Abo', 1::smallint, 'month'::finance.schedule_unit, 1::smallint,
                                         '2026-06-01', '2026-06-01', NULL, NULL, NULL);

  SELECT finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [skip]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_rp AND due_date = v_due) THEN
    RAISE EXCEPTION 'FAIL [skip]: Skip-Zeile fehlt';
  END IF;
  RAISE NOTICE 'PASS [skip]: Zeile vorhanden';

  -- Idempotent: nochmal skippen -> ok:true, weiterhin genau 1 Zeile
  SELECT finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (SELECT count(*) FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_rp AND due_date = v_due) <> 1 THEN
    RAISE EXCEPTION 'FAIL [skip idempotent]: nicht genau 1 Zeile';
  END IF;
  RAISE NOTICE 'PASS [skip idempotent] = 1 Zeile';

END $$;

ROLLBACK;
