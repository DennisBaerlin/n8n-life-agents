-- tests/db/core/test_core_context_validators.sql
-- WS-B1 (Phase 3b): generische Validator-Registry core.context_validators. Sichert die strukturellen
-- Invarianten der Host-Tabelle (DB ist Gesetz), unabhaengig vom Dispatch-Verhalten (das deckt
-- test_fn_validate_finance_profile / test_fn_household_facts ab):
--   (1) gueltige schema-qualifizierte Bindung wird akzeptiert,
--   (2) CHECK weist nicht-qualifizierte / nicht-konforme Bezeichner ab (Injection-Schutz),
--   (3) PRIMARY KEY erzwingt EIN Validator je Context (erstes Paket gewinnt, Zweit-Bindung kollidiert).
BEGIN;

DO $$
BEGIN
  -- ---------- TEST 1: gueltige Bindung akzeptiert ----------
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance');
  RAISE NOTICE 'PASS [gueltige schema-qualifizierte Bindung akzeptiert]';

  -- ---------- TEST 2: PRIMARY KEY -> ein Validator je Context ----------
  BEGIN
    INSERT INTO core.context_validators (context_name, validate_fn, package)
    VALUES ('finance_profile', 'other.fn_x', 'other');
    RAISE EXCEPTION 'FAIL [pk]: doppelter context_name akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [PRIMARY KEY: ein Validator je Context, Zweit-Bindung kollidiert]';
  END;

  -- ---------- TEST 3a: CHECK weist nicht-qualifizierten Namen (kein Schema) ab ----------
  BEGIN
    INSERT INTO core.context_validators (context_name, validate_fn)
    VALUES ('foo', 'fn_no_schema');
    RAISE EXCEPTION 'FAIL [check no-schema]: unqualifizierter Bezeichner akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: unqualifizierter Bezeichner abgewiesen]';
  END;

  -- ---------- TEST 3b: CHECK weist Injection-/Sonderzeichen ab ----------
  BEGIN
    INSERT INTO core.context_validators (context_name, validate_fn)
    VALUES ('bar', 'finance.fn_x; DROP TABLE core.config');
    RAISE EXCEPTION 'FAIL [check injection]: Bezeichner mit Sonderzeichen akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: Injection-/Sonderzeichen abgewiesen]';
  END;

  -- ---------- TEST 3c: CHECK weist Grossbuchstaben ab (lowercase-Konvention) ----------
  BEGIN
    INSERT INTO core.context_validators (context_name, validate_fn)
    VALUES ('baz', 'Finance.Fn_Mixed');
    RAISE EXCEPTION 'FAIL [check uppercase]: Mixed-Case-Bezeichner akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [CHECK: Mixed-Case abgewiesen]';
  END;
END $$;

ROLLBACK;
