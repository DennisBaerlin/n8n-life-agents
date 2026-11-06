-- tests/db/finance/test_fn_interest_eligible_account_type.sql
-- WS-Z4: zins-faehige Kontotypen (Allowlist cash/fixed_deposit/p2p) + struktureller Backstop-Trigger.
--   (1) fn_interest_eligible_account_type-Matrix; (2) trg_finance_reject_interest_rate_ineligible sperrt
--   eine Zinszeile auf Depot/Kredit hart (RAISE); (3) fn_create_account mit Zins auf Nicht-Eligible lehnt
--   korrigierbar ab (Import-Haertung 2026-10-22: {ok:false} VOR dem Write statt Trigger-RAISE/Owner-Alert; der
--   Trigger aus (2) bleibt der strukturelle Backstop).
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_loan_id INT;
  v_blocked BOOLEAN;
BEGIN
  -- ===== (1) Allowlist-Matrix =====
  IF finance.fn_interest_eligible_account_type('cash')          IS DISTINCT FROM true  THEN RAISE EXCEPTION 'FAIL [matrix cash]'; END IF;
  IF finance.fn_interest_eligible_account_type('fixed_deposit') IS DISTINCT FROM true  THEN RAISE EXCEPTION 'FAIL [matrix fixed_deposit]'; END IF;
  IF finance.fn_interest_eligible_account_type('p2p')           IS DISTINCT FROM true  THEN RAISE EXCEPTION 'FAIL [matrix p2p]'; END IF;
  IF finance.fn_interest_eligible_account_type('stocks_depot')  IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [matrix stocks_depot]'; END IF;
  IF finance.fn_interest_eligible_account_type('crypto_depot')  IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [matrix crypto_depot]'; END IF;
  IF finance.fn_interest_eligible_account_type('loan')          IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [matrix loan]'; END IF;
  RAISE NOTICE 'PASS [Allowlist-Matrix: cash/fixed_deposit/p2p=true, stocks_depot/crypto_depot/loan=false]';

  -- ===== (2) Trigger sperrt eine Zinszeile auf einem Kredit-Konto (Direkt-Insert) =====
  -- loan-Konto direkt (fn_create_account lehnt loan ab; Kredit-Konten legt nur fn_create_loan an)
  INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test_elig_loan__', 'loan', 'EUR')
  RETURNING id INTO v_loan_id;
  v_blocked := false;
  BEGIN
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, valid_from)
    VALUES (v_loan_id, 4, 1, 'month', '2026-01-01');
  EXCEPTION WHEN others THEN
    v_blocked := true;
    IF SQLERRM NOT LIKE '%not eligible%' THEN RAISE; END IF;   -- nur den Eligibility-RAISE schlucken
  END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL [trigger]: Zinszeile auf loan haette abgelehnt werden muessen'; END IF;
  RAISE NOTICE 'PASS [Trigger: Direkt-Insert einer Zinszeile auf Kredit-Konto -> RAISE]';

  -- ===== (3) fn_create_account mit Zins auf Nicht-Eligible -> {ok:false} OHNE Write =====
  -- (Depot statt Kredit: account_type loan lehnt fn_create_account schon vorher mit ok:false ab)
  DECLARE v_settle INT; BEGIN
    INSERT INTO finance.accounts (name, account_type) VALUES ('__test_elig_settle__', 'cash') RETURNING id INTO v_settle;
    SELECT finance.fn_create_account(jsonb_build_object('name','__test_elig_depot2__','account_type','stocks_depot',
      'settlement_id', v_settle, 'currency','EUR','interest_rate',3)) INTO v_res;
  END;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [create-path]: Depot MIT Zins muss ok:false liefern, got %', v_res;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__test_elig_depot2__') THEN
    RAISE EXCEPTION 'FAIL [create-path]: nach ok:false darf das Konto NICHT existieren';
  END IF;
  RAISE NOTICE 'PASS [create-path: Zins auf Depot -> ok:false, nichts angelegt]';
END $$;

ROLLBACK;
