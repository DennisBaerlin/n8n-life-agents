-- tests/db/finance/test_fn_liability_register.sql
-- WS-0b (estate): finance.fn_liability_register() = Oberflaeche-A-Lesefenster fuer das estate-Paket
-- (plain STABLE, kein Grant). Prueft: AKTIVE/PAUSIERTE Kredite mit Restschuld (EUR-Basis), abgeloeste
-- (paid_off) ausgeschlossen, Rueckgabe ist ein JSON-Array.
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_debit    INT;
  v_disb     INT;
  v_loan_id  INT;
  v_reg      JSONB;
  v_row      JSONB;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_liabreg_debit__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_debit := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    '{"name":"__test_liabreg_disb__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_disb := (v_result->>'account_id')::int;

  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_liabreg_kredit__','lender','TestBank','original_amount',200000,
    'disbursement_date','2024-01-15','interest_rate','3.0','principal_rate','1.0',
    'monthly_annuity',800,'schedule_day_of_month','15','first_payment_date','2024-02-15',
    'disbursement_account_id',v_disb,'debit_account_id',v_debit
  )) INTO v_result;
  v_loan_id := (v_result->>'loan_id')::int;

  v_reg := finance.fn_liability_register();
  IF jsonb_typeof(v_reg) <> 'array' THEN
    RAISE EXCEPTION 'FAIL fn_liability_register: kein JSON-Array, got %', v_reg;
  END IF;

  SELECT e INTO v_row FROM jsonb_array_elements(v_reg) e WHERE e->>'name' = '__test_liabreg_kredit__';
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_liability_register: aktiver Kredit fehlt im Register';
  END IF;
  IF (v_row->>'id')::int IS DISTINCT FROM v_loan_id
     OR v_row->>'lender' IS DISTINCT FROM 'TestBank'
     OR (v_row->>'original_amount')::numeric IS DISTINCT FROM 200000
     -- Audit Paket 2 (Punkt 10): Register = Betrag der Schuld, POSITIV (vorher -200000 -> estate rendert
     -- "Restschuld ~-200000 EUR"). Bewusste Vertragsaenderung.
     OR (v_row->>'current_remaining_debt_eur')::numeric IS DISTINCT FROM 200000
     OR v_row->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL fn_liability_register: Felder falsch, got %', v_row;
  END IF;

  -- abgeloeste (paid_off) Kredite fallen aus dem Register (Read-Filter direkt geprueft).
  UPDATE finance.loans SET status = 'paid_off' WHERE id = v_loan_id;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(finance.fn_liability_register()) e
    WHERE e->>'name' = '__test_liabreg_kredit__'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_liability_register: paid_off-Kredit nicht ausgeschlossen';
  END IF;

  RAISE NOTICE 'PASS fn_liability_register [aktiver Kredit mit Restschuld EUR, paid_off ausgeschlossen, JSON-Array]';
END $$;

ROLLBACK;
