-- tests/db/core/test_fn_package_active.sql
-- WS-B8 R4: core.fn_package_active(text) -> boolean (publiziertes SECURITY-DEFINER-Read-Window).
--   Pass-Bedingung = status='active' EXAKT; installing/installed/inactive/unbekannt/NULL -> false; 'core' -> true.
--   Muster: BEGIN…ROLLBACK, eigene Zeilen seeden (db_test hat kein seed_data). RAISE EXCEPTION 'FAIL …' = Test rot.
-- VF3 (Auth, D10): finance_ro ruft die DEFINER-fn ueber den EXECUTE-Grant, hat aber KEIN direktes
--   SELECT auf core.package_registry (Isolation haelt) — beweist die kontrollierte Grenz-Ueberschreitung.
BEGIN;

DO $$
DECLARE v_pkg text := '__test_pkg_active__';
BEGIN
  INSERT INTO core.package_registry (package, version, status)
  VALUES (v_pkg, '1.0.0', 'installing')
  ON CONFLICT (package) DO UPDATE SET status = EXCLUDED.status;

  -- Status-Matrix: nur 'active' -> true.
  IF core.fn_package_active(v_pkg) THEN RAISE EXCEPTION 'FAIL [installing -> true]'; END IF;
  UPDATE core.package_registry SET status = 'installed' WHERE package = v_pkg;
  IF core.fn_package_active(v_pkg) THEN RAISE EXCEPTION 'FAIL [installed -> true]'; END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = v_pkg;
  IF core.fn_package_active(v_pkg) THEN RAISE EXCEPTION 'FAIL [inactive -> true]'; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = v_pkg;
  IF NOT core.fn_package_active(v_pkg) THEN RAISE EXCEPTION 'FAIL [active -> false]'; END IF;

  -- Unbekanntes Paket + NULL -> false (fail-closed auf expliziten Nicht-active-Zustand).
  IF core.fn_package_active('__does_not_exist__') THEN RAISE EXCEPTION 'FAIL [unknown -> true]'; END IF;
  IF core.fn_package_active(NULL) THEN RAISE EXCEPTION 'FAIL [NULL -> true]'; END IF;

  -- Host-Paket 'core' ist immer aktiv (im Prod via register_packages geseedet; hier deterministisch setzen).
  INSERT INTO core.package_registry (package, version, status)
  VALUES ('core', '0.1.0', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  IF NOT core.fn_package_active('core') THEN RAISE EXCEPTION 'FAIL [core -> false]'; END IF;

  RAISE NOTICE 'PASS core.fn_package_active [Status-Matrix + NULL/unknown/core]';
END $$;

-- ---------- VF3 (D10): finance_ro via DEFINER-Fenster; KEIN direkter Tabellen-Read ----------
-- Voraussetzung: EXECUTE-Grant aus fn_provision_package_roles (bootstrap_test_db). Superuser -> SET LOCAL ROLE.
DO $$
DECLARE v_active boolean; v_blocked boolean := false;
BEGIN
  INSERT INTO core.package_registry (package, version, status)
  VALUES ('finance', '0.1.0', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';

  SET LOCAL ROLE finance_ro;
  v_active := core.fn_package_active('finance');     -- EXECUTE-Grant greift
  BEGIN
    PERFORM 1 FROM core.package_registry WHERE package = 'finance';   -- muss scheitern (Isolation)
  EXCEPTION WHEN insufficient_privilege THEN v_blocked := true;
  END;
  RESET ROLE;

  IF v_active IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro konnte fn_package_active nicht aufrufen / kein true]: %', v_active; END IF;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro hat direkten SELECT auf core.package_registry]'; END IF;

  RAISE NOTICE 'PASS VF3 [finance_ro liest Paket-Status nur ueber das publizierte DEFINER-Fenster]';
END $$;

ROLLBACK;
