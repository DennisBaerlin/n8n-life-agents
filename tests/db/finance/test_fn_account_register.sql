-- tests/db/finance/test_fn_account_register.sql
-- WS-0b (estate): finance.fn_account_register() = Oberflaeche-A-Lesefenster fuer das estate-Paket
-- (plain STABLE, kein Grant). Prueft: aktive NICHT-Loan-Konten mit den estate-relevanten Feldern
-- (ownership/has_transmortal_poa), Loan-Konten ausgeschlossen (die deckt fn_liability_register),
-- Rueckgabe ist ein JSON-Array.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_reg    JSONB;
  v_row    JSONB;
BEGIN
  SELECT finance.fn_create_account(
    '{"name":"__test_accreg_giro__","account_type":"cash","bank":"TestBank","account_number":"DE00","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- ownership + transmortale Bankvollmacht via fn_set_account setzen
  PERFORM finance.fn_set_account(jsonb_build_object(
    'account_id',v_acct,'ownership','joint_or','has_transmortal_poa','true'));

  v_reg := finance.fn_account_register();
  IF jsonb_typeof(v_reg) <> 'array' THEN
    RAISE EXCEPTION 'FAIL fn_account_register: kein JSON-Array, got %', v_reg;
  END IF;

  SELECT e INTO v_row FROM jsonb_array_elements(v_reg) e WHERE e->>'name' = '__test_accreg_giro__';
  IF v_row IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_account_register: Konto fehlt im Register';
  END IF;
  IF (v_row->>'id')::int IS DISTINCT FROM v_acct
     OR v_row->>'account_type' IS DISTINCT FROM 'cash'
     OR v_row->>'bank' IS DISTINCT FROM 'TestBank'
     OR v_row->>'ownership' IS DISTINCT FROM 'joint_or'
     OR (v_row->>'has_transmortal_poa')::boolean IS DISTINCT FROM true
     OR v_row->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL fn_account_register: estate-Felder falsch, got %', v_row;
  END IF;

  -- Loan-Konto darf NICHT erscheinen (Trennung Konten-Register <-> Verbindlichkeiten-Register).
  -- loan-Konto direkt (fn_create_account lehnt loan ab; Kredit-Konten legt nur fn_create_loan an)
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test_accreg_loanacct__', 'loan', 'EUR');
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(finance.fn_account_register()) e
    WHERE e->>'name' = '__test_accreg_loanacct__'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_account_register: Loan-Konto nicht ausgeschlossen';
  END IF;

  RAISE NOTICE 'PASS fn_account_register [ownership+POA, Loan-Konto ausgeschlossen, JSON-Array]';
END $$;

ROLLBACK;
