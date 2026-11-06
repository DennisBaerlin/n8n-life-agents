-- tests/db/core/test_fn_facts_context_allowed.sql
-- Testet core.fn_facts_context_allowed (Install-UX-Phase 6, Naht finance_profile): welche Fakten-Kontexte
-- der Haushalts-Schreibpfad (fn_set_context_facts + Lern-Loop-Vorfilter) beschreiben darf.
--   family immer; sonst nur ein in core.context_validators registrierter HAUSHALTS-Kontext (scope household
--   bzw. ohne Scope-Zeile) eines AKTIVEN Pakets. per_user-Kontexte (career_profile) gehoeren dem
--   person-skopierten fn_set_context_facts — nie diesem Pfad (sonst fehlte der Personen-Suffix).
-- Pattern: BEGIN…ROLLBACK, RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen.
BEGIN;

DO $$
BEGIN
  -- Fixture (db_test hat kein seed_data): zwei Registry-Pakete + ihre Kontext-Registrierungen.
  INSERT INTO core.package_registry (package, status) VALUES ('__t_hh__', 'active'), ('__t_pu__', 'active')
  ON CONFLICT (package) DO UPDATE SET status = EXCLUDED.status;
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('__t_hh_profile__', 'finance.fn_validate_finance_profile', '__t_hh__'),
         ('__t_pu_profile__', 'finance.fn_validate_finance_profile', '__t_pu__')
  ON CONFLICT (context_name) DO UPDATE SET package = EXCLUDED.package;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__t_pu_profile__', 'per_user', 'own_user_only', '__t_pu__')
  ON CONFLICT (context_name) DO UPDATE SET scope = EXCLUDED.scope, write_permission = EXCLUDED.write_permission;

  -- (1) family ist immer erlaubt (Host-Kontext, keine Registry-Zeile noetig).
  IF NOT core.fn_facts_context_allowed('family') THEN
    RAISE EXCEPTION 'FAIL: family nicht erlaubt';
  END IF;

  -- (2) registrierter Haushalts-Kontext (ohne Scope-Zeile = household) eines aktiven Pakets -> erlaubt.
  IF NOT core.fn_facts_context_allowed('__t_hh_profile__') THEN
    RAISE EXCEPTION 'FAIL: registrierter Haushalts-Kontext eines aktiven Pakets nicht erlaubt';
  END IF;

  -- (3) Paket ausgeschaltet -> nicht erlaubt.
  UPDATE core.package_registry SET status = 'inactive' WHERE package = '__t_hh__';
  IF core.fn_facts_context_allowed('__t_hh_profile__') THEN
    RAISE EXCEPTION 'FAIL: Kontext eines ausgeschalteten Pakets erlaubt';
  END IF;

  -- (4) Paket nicht (mehr) registriert -> nicht erlaubt.
  DELETE FROM core.package_registry WHERE package = '__t_hh__';
  IF core.fn_facts_context_allowed('__t_hh_profile__') THEN
    RAISE EXCEPTION 'FAIL: Kontext eines nicht installierten Pakets erlaubt';
  END IF;

  -- (5) per_user-Kontext eines aktiven Pakets -> NICHT erlaubt (gehoert fn_set_context_facts).
  IF core.fn_facts_context_allowed('__t_pu_profile__') THEN
    RAISE EXCEPTION 'FAIL: per_user-Kontext ueber den Haushalts-Pfad erlaubt';
  END IF;

  -- (6) unregistrierter Name / Instruktions-Kontext / NULL -> nicht erlaubt.
  IF core.fn_facts_context_allowed('global_instructions') OR core.fn_facts_context_allowed('__nope__')
     OR COALESCE(core.fn_facts_context_allowed(NULL), false) THEN
    RAISE EXCEPTION 'FAIL: unregistrierter Kontext erlaubt';
  END IF;

  RAISE NOTICE 'PASS core.fn_facts_context_allowed: family / household+aktiv / inaktiv / nicht installiert / per_user / unregistriert';
END $$;

ROLLBACK;
