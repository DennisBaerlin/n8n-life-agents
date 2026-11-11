-- tests/db/finance/test_fn_next_step_example.sql
-- finance.fn_next_step_example(p_person_id text) — Beispielsatz fuer den naechsten Schritt (Aufrufer: core.fn_get_next_step_example).
-- Key 'finance.next_step.example' genau dann, wenn ein Geld-Konto nach der Regel der Plan-Reife existiert UND die Person
-- den Haushalt sieht (owner/partner); sonst NULL. Der Onboarding-Abschnittsstatus zaehlt nicht.
--   1) kein Konto / nur Depot / geschlossenes Geld-Konto -> NULL
--   2) Geld-Konto da: owner/partner -> Key; child, unbekannt, NULL -> NULL; Abschnitt accounts uebersprungen -> Key
--   3) Vertrag des Aufrufers: DEFINER, search_path gepinnt, Eigentuemer = Eigentuemer von Schema core, kein EXECUTE fuer PUBLIC
-- Der Key selbst (de/en/ko, ohne {param}) steht in packages/finance/locales/*.json, Gleichstand prueft locale_lint; die
-- Test-DB seedet keinen Textkatalog.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_acct int;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('nse_owner',   'Owner Testfall',   'owner'),
    ('nse_partner', 'Partner Testfall', 'partner'),
    ('nse_kid',     'Kind Testfall',    'child')
  ON CONFLICT (person_id) DO UPDATE SET role = EXCLUDED.role;

  -- Fixture-unabhaengig: alle Geld-Konten schliessen
  UPDATE finance.accounts SET status = 'closed' WHERE account_type = 'cash';

  -- (1) kein Geld-Konto
  IF finance.fn_next_step_example('nse_owner') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1a] ohne Geld-Konto kein Beispiel'; END IF;
  INSERT INTO finance.accounts (name, account_type) VALUES ('__t_nse_giro', 'cash') RETURNING id INTO v_acct;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_acct;
  INSERT INTO finance.accounts (name, account_type, settlement_account_id) VALUES ('__t_nse_depot', 'stocks_depot', v_acct);
  IF finance.fn_next_step_example('nse_owner') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1b] ein Depot allein ist kein Geld-Konto'; END IF;
  IF finance.fn_next_step_example('nse_owner') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1c] ein geschlossenes Geld-Konto zaehlt nicht'; END IF;
  RAISE NOTICE 'PASS [1] ohne aktives Geld-Konto NULL';

  -- (2) Geld-Konto aktiv
  UPDATE finance.accounts SET status = 'active' WHERE id = v_acct;
  IF finance.fn_next_step_example('nse_owner') IS DISTINCT FROM 'finance.next_step.example'
     OR finance.fn_next_step_example('nse_partner') IS DISTINCT FROM 'finance.next_step.example' THEN
    RAISE EXCEPTION 'FAIL [2a] owner/partner mit Geld-Konto bekommen den Key'; END IF;
  IF finance.fn_next_step_example('nse_kid') IS NOT NULL
     OR finance.fn_next_step_example('nse_nobody') IS NOT NULL
     OR finance.fn_next_step_example(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2b] child/unbekannt/NULL bekommen kein Beispiel'; END IF;
  UPDATE finance.onboarding_state SET status = 'skipped' WHERE section_key = 'accounts';
  IF finance.fn_next_step_example('nse_owner') IS DISTINCT FROM 'finance.next_step.example' THEN
    RAISE EXCEPTION 'FAIL [2c] uebersprungener Abschnitt mit Geld-Konto: Key trotzdem'; END IF;
  RAISE NOTICE 'PASS [2] owner/partner Key, Kind/unbekannt NULL, Abschnittsstatus egal';

  -- (3) Vertrag, den core zur Laufzeit ueber pg_proc prueft
  IF NOT EXISTS (SELECT 1 FROM pg_proc p
                  WHERE p.oid = 'finance.fn_next_step_example(text)'::regprocedure
                    AND p.prosecdef
                    AND 'search_path=pg_catalog, pg_temp' = ANY (p.proconfig)
                    AND p.proowner = (SELECT nspowner FROM pg_namespace WHERE nspname = 'core')) THEN
    RAISE EXCEPTION 'FAIL [3a] DEFINER + gepinnter search_path + Eigentuemer von Schema core verlangt'; END IF;
  IF has_function_privilege('public', 'finance.fn_next_step_example(text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [3b] kein EXECUTE fuer PUBLIC'; END IF;
  RAISE NOTICE 'PASS [3] Aufrufer-Vertrag erfuellt';
END $$;
ROLLBACK;
