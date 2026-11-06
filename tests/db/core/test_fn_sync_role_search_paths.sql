-- tests/db/core/test_fn_sync_role_search_paths.sql
-- Testet core.fn_sync_role_search_paths(role): Desired-State-FULL-REPLACE des Rollen-
--   search_path = Basis (pg_catalog, agent, core) + ein Tail-Eintrag je registriertem Paket,
--   DESSEN SCHEMA EXISTIERT (to_regnamespace NOT NULL — NICHT status='active', sonst faellt
--   das gerade installierende Paket raus), sortiert. Generisch statt finance-Hardcode (B).
-- Nur eine WEGWERF-Rolle wird synchronisiert (nie das echte core_ro/owner in der TX).
-- ISOLATION: `DELETE FROM core.package_registry` zu Beginn der TX -> die Assertions sehen NUR
--   die Wegwerf-Pakete (die echten core/finance/career-Zeilen kommen beim ROLLBACK zurueck;
--   package_registry hat KEINE eingehenden FKs + nur einen BEFORE-UPDATE-Touch-Trigger).
-- Pattern: BEGIN…ROLLBACK; RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_path   TEXT;
  v_cfg    TEXT;
  v_raised BOOLEAN;
BEGIN
  -- Clean slate (rollt zurueck): nur die Wegwerf-Pakete sollen sichtbar sein.
  DELETE FROM core.package_registry;

  -- Wegwerf-Rolle (nur zum ALTER; kein LOGIN noetig) + zwei Wegwerf-Paket-Schemas.
  CREATE ROLE tst_sp_role;
  CREATE SCHEMA tst_sp_a;
  CREATE SCHEMA tst_sp_b;

  INSERT INTO core.package_registry (package, status) VALUES
    ('tst_sp_a', 'active'),        -- Schema existiert
    ('tst_sp_b', 'installing'),    -- (6) NICHT active, aber Schema existiert -> MUSS inkludiert sein
    ('tst_sp_c', 'active'),        -- (2) KEIN Schema -> MUSS ausgelassen werden
    ('core',     'active');        -- (5) core ist in der Basis -> NIE im Tail (sonst doppelt)

  -- (1) Basis + Tail, sortiert, nur existierende Nicht-core-Schemas. Der exakte Match beweist
  --     zugleich (2) kein tst_sp_c, (5) kein doppeltes core, (6) installing-b ist dabei.
  v_path := core.fn_sync_role_search_paths('tst_sp_role');
  IF v_path <> 'pg_catalog, agent, core, tst_sp_a, tst_sp_b' THEN
    RAISE EXCEPTION 'FAIL (1) Pfad = "%" (erwartet "pg_catalog, agent, core, tst_sp_a, tst_sp_b")', v_path;
  END IF;
  IF position('tst_sp_c' in v_path) > 0 THEN RAISE EXCEPTION 'FAIL (2): tst_sp_c (kein Schema) im Pfad'; END IF;
  IF position('tst_sp_b' in v_path) = 0 THEN RAISE EXCEPTION 'FAIL (6): tst_sp_b (installing) fehlt im Pfad'; END IF;

  -- Der ALTER ROLE hat GEGRIFFEN: rolconfig traegt exakt denselben Pfad.
  SELECT s INTO v_cfg
  FROM pg_roles r, unnest(r.rolconfig) AS s
  WHERE r.rolname = 'tst_sp_role' AND s LIKE 'search_path=%';
  IF v_cfg IS DISTINCT FROM ('search_path=' || v_path) THEN
    RAISE EXCEPTION 'FAIL rolconfig = "%" (erwartet "search_path=%")', v_cfg, v_path;
  END IF;

  -- (3) Self-Heal: Schema a droppen -> a faellt aus dem Pfad (Desired-State, kein Append).
  DROP SCHEMA tst_sp_a;
  v_path := core.fn_sync_role_search_paths('tst_sp_role');
  IF v_path <> 'pg_catalog, agent, core, tst_sp_b' THEN
    RAISE EXCEPTION 'FAIL (3) Self-Heal: Pfad = "%" (erwartet "pg_catalog, agent, core, tst_sp_b")', v_path;
  END IF;

  -- (4) Idempotenz: erneuter Aufruf ohne Aenderung -> identisch.
  IF core.fn_sync_role_search_paths('tst_sp_role') <> v_path THEN
    RAISE EXCEPTION 'FAIL (4): nicht idempotent';
  END IF;

  -- (7) leerer Tail: keine Nicht-core-Pakete mehr -> nur die Basis.
  DROP SCHEMA tst_sp_b;
  DELETE FROM core.package_registry WHERE package LIKE 'tst_sp_%';
  v_path := core.fn_sync_role_search_paths('tst_sp_role');
  IF v_path <> 'pg_catalog, agent, core' THEN
    RAISE EXCEPTION 'FAIL (7) leerer Tail: Pfad = "%" (erwartet "pg_catalog, agent, core")', v_path;
  END IF;

  -- (8) nicht existente Rolle -> Fehler (kein stiller Durchlauf/ALTER auf nichts).
  v_raised := false;
  BEGIN
    PERFORM core.fn_sync_role_search_paths('__no_such_role__');
  EXCEPTION WHEN OTHERS THEN v_raised := true;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL (8): nicht existente Rolle nicht abgelehnt'; END IF;

  RAISE NOTICE 'PASS fn_sync_role_search_paths: Basis+Tail/Schema-exists-Praedikat/Self-Heal/Idempotenz/leer/Rollen-Guard';
END $$;

ROLLBACK;
