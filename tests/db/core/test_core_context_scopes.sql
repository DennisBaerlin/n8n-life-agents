-- tests/db/core/test_core_context_scopes.sql
-- P0a: deklarative Scope-/Permission-Registry core.context_scopes. Sichert die strukturellen Invarianten der
-- Host-Tabelle (DB ist Gesetz), unabhaengig von der Durchsetzung (die deckt test_fn_check_write_permission ab):
--   (1) gueltige Zeile akzeptiert,
--   (2) scope-CHECK weist Fremdwert ab,
--   (3) write_permission-CHECK weist Fremdwert ab,
--   (4) Cross-CHECK: own_user_only setzt per_user voraus (own_user_only+household abgewiesen, +per_user ok),
--   (5) PRIMARY KEY erzwingt EINE Zeile je Context (erstes Paket gewinnt, Zweit-Bindung kollidiert).
BEGIN;

DO $$
BEGIN
  -- ---------- TEST 1: gueltige Zeile akzeptiert ----------
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile', 'household', 'owner_only', 'career');
  RAISE NOTICE 'PASS [gueltige household/owner_only-Zeile akzeptiert]';

  -- ---------- TEST 2: scope-CHECK weist Fremdwert ab ----------
  BEGIN
    INSERT INTO core.context_scopes (context_name, scope, write_permission)
    VALUES ('x_scope', 'global', 'owner_only');
    RAISE EXCEPTION 'FAIL [scope-check]: Fremd-scope akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [scope-CHECK: Fremdwert abgewiesen]';
  END;

  -- ---------- TEST 3: write_permission-CHECK weist Fremdwert ab ----------
  BEGIN
    INSERT INTO core.context_scopes (context_name, scope, write_permission)
    VALUES ('x_perm', 'household', 'admins_only');
    RAISE EXCEPTION 'FAIL [perm-check]: Fremd-write_permission akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [write_permission-CHECK: Fremdwert abgewiesen]';
  END;

  -- ---------- TEST 4a: Cross-CHECK: own_user_only + household abgewiesen ----------
  BEGIN
    INSERT INTO core.context_scopes (context_name, scope, write_permission)
    VALUES ('x_cross', 'household', 'own_user_only');
    RAISE EXCEPTION 'FAIL [cross-check]: own_user_only+household akzeptiert (per_user nicht erzwungen)';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [Cross-CHECK: own_user_only setzt per_user voraus]';
  END;

  -- ---------- TEST 4b: own_user_only + per_user akzeptiert ----------
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning', 'per_user', 'own_user_only', 'career');
  RAISE NOTICE 'PASS [own_user_only + per_user akzeptiert]';

  -- ---------- TEST 5: PRIMARY KEY -> eine Zeile je Context ----------
  BEGIN
    INSERT INTO core.context_scopes (context_name, scope, write_permission)
    VALUES ('career_profile', 'per_user', 'own_user_only');
    RAISE EXCEPTION 'FAIL [pk]: doppelter context_name akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS [PRIMARY KEY: eine Zeile je Context, Zweit-Bindung kollidiert]';
  END;
END $$;

ROLLBACK;
