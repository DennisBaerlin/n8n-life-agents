-- tests/db/core/test_fn_pkg_roles.sql
-- Testet das per-Paket-Rollen-/Privileg-Modell (Core-Paket-Framework, Phase 1, D10):
--   core.fn_provision_package_roles / core.fn_drop_package_roles +
--   das SECURITY-DEFINER-Read-fn-Muster (core.fn_core_api_version).
-- KERNAUSSAGE (VF3): eine Paket-Rolle erreicht NUR ihr eigenes Schema; agent.*/core.*-
--   Tabellen scheitern PHYSISCH ("permission denied"), Core-Daten nur ueber die
--   publizierten SECURITY-DEFINER-Read-fns. Rollen sind cluster-global, aber CREATE/DROP
--   ROLE ist transaktional -> BEGIN…ROLLBACK raeumt sie restlos weg.
-- Pattern: BEGIN…ROLLBACK; RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_denied BOOLEAN;
  v_res    JSONB;
  v_api    TEXT;
BEGIN
  -- Setup: bekannte CORE_API_VERSION (im Prod via manifest .config geseedet).
  INSERT INTO core.config (category, key, value)
  VALUES ('api', 'core_version', '0.1.0')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;

  -- Wegwerf-Paket-Schema mit einer Tabelle + Zeile (als Superuser angelegt = postgres besitzt es).
  CREATE SCHEMA test_pkg;
  CREATE TABLE test_pkg.thing (id int PRIMARY KEY, label text);
  INSERT INTO test_pkg.thing VALUES (1, 'hello');

  -- (1) provision: legt test_pkg_rw + test_pkg_ro an.
  v_res := core.fn_provision_package_roles(jsonb_build_object('package', 'test_pkg'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL provision: %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_pkg_rw') THEN RAISE EXCEPTION 'FAIL: rw-Rolle fehlt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'test_pkg_ro') THEN RAISE EXCEPTION 'FAIL: ro-Rolle fehlt'; END IF;

  -- (2) provision erneut = idempotent (Re-Install darf nicht scheitern).
  v_res := core.fn_provision_package_roles(jsonb_build_object('package', 'test_pkg'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL re-provision nicht idempotent: %', v_res; END IF;

  -- (3) ungueltiger Paketname -> {ok:false} ohne Write (korrigierbar).
  v_res := core.fn_provision_package_roles(jsonb_build_object('package', 'Bad-Name'));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL: ungueltiger Paketname akzeptiert (%)', v_res; END IF;

  -- (4) nicht existentes Schema -> {ok:false}.
  v_res := core.fn_provision_package_roles(jsonb_build_object('package', '__no_such_schema__'));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL: fehlendes Schema akzeptiert (%)', v_res; END IF;

  -- (5) ro DARF das EIGENE Schema lesen.
  SET LOCAL ROLE test_pkg_ro;
  PERFORM 1 FROM test_pkg.thing;
  RESET ROLE;

  -- (6) ro kann agent.* NICHT erreichen (VF3 — permission denied for schema agent).
  SET LOCAL ROLE test_pkg_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3: test_pkg_ro erreichte agent.core_contexts'; END IF;

  -- (7) ro kann core-Tabellen NICHT direkt lesen (USAGE on core ja, aber kein Tabellen-GRANT).
  SET LOCAL ROLE test_pkg_ro;
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM core.config LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: test_pkg_ro las core.config direkt'; END IF;

  -- (8) ro erreicht CORE_API_VERSION NUR ueber die SECURITY-DEFINER-Read-fn.
  SET LOCAL ROLE test_pkg_ro;
  v_api := core.fn_core_api_version();
  RESET ROLE;
  IF v_api <> '0.1.0' THEN RAISE EXCEPTION 'FAIL: fn_core_api_version via ro = % (erwartet 0.1.0)', v_api; END IF;

  -- (9) ro ist read-only: INSERT ins eigene Schema scheitert (kein INSERT-GRANT).
  SET LOCAL ROLE test_pkg_ro;
  v_denied := FALSE;
  BEGIN INSERT INTO test_pkg.thing VALUES (2, 'nope');
  EXCEPTION WHEN insufficient_privilege OR read_only_sql_transaction THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: test_pkg_ro konnte schreiben'; END IF;

  -- (10) rw DARF das eigene Schema beschreiben, erreicht agent.* aber NICHT.
  SET LOCAL ROLE test_pkg_rw;
  INSERT INTO test_pkg.thing VALUES (3, 'rw-wrote');
  v_denied := FALSE;
  BEGIN PERFORM 1 FROM agent.core_contexts LIMIT 1;
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL VF3: test_pkg_rw erreichte agent.core_contexts'; END IF;

  -- (11) rw darf KEINE Objekte im Schema anlegen (R11 — kein Schema-/Core-DDL).
  SET LOCAL ROLE test_pkg_rw;
  v_denied := FALSE;
  BEGIN EXECUTE 'CREATE TABLE test_pkg.evil (id int)';
  EXCEPTION WHEN insufficient_privilege THEN v_denied := TRUE; END;
  RESET ROLE;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL: test_pkg_rw konnte DDL im Schema'; END IF;

  -- (12) drop: entfernt beide Rollen (purge-Pfad).
  v_res := core.fn_drop_package_roles(jsonb_build_object('package', 'test_pkg'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL drop: %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname IN ('test_pkg_rw', 'test_pkg_ro'))
     THEN RAISE EXCEPTION 'FAIL drop: Rollen noch da'; END IF;

  -- (13) drop erneut = idempotent (kein RAISE, removed=false).
  v_res := core.fn_drop_package_roles(jsonb_build_object('package', 'test_pkg'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL drop idempotent: %', v_res; END IF;
  IF (v_res->>'dropped')::bool IS DISTINCT FROM FALSE THEN RAISE EXCEPTION 'FAIL drop idempotent: dropped != false (%)', v_res; END IF;

  RAISE NOTICE 'PASS core package roles: provision/Isolation(VF3)/SECURITY-DEFINER-Read-fn/drop';
END $$;

ROLLBACK;
