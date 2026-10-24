-- tests/db/core/test_fn_pkg_registry.sql
-- Testet die PackageRegistry-Schicht (Core-Paket-Framework, Phase 1):
--   core.package_registry (Tabelle/CHECKs) + core.fn_pkg_register/set_status/check_deps/remove.
-- Pattern: BEGIN…ROLLBACK, erwartete Blockaden in inneren BEGIN/EXCEPTION-Bloecken.
--   RAISE EXCEPTION 'FAIL …' = Test fehlgeschlagen (ON_ERROR_STOP -> Exit 1).
BEGIN;

DO $$
DECLARE
  v_blocked BOOLEAN;
  v_res     JSONB;
BEGIN
  -- Setup: ein bekanntes CORE_API_VERSION (im Prod via manifest .config geseedet).
  --   Wir setzen es hier deterministisch fuer den core_api-Range-Check.
  INSERT INTO core.config (category, key, value)
  VALUES ('api', 'core_version', '0.3.0')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;

  -- (1) register: legt das Paket im Status 'installing' an, created=true.
  v_res := core.fn_pkg_register(jsonb_build_object(
    'package', '__test_pkg__', 'version', '1.0.0', 'description', 'Testpaket',
    'core_api', '0.2.0', 'requires', jsonb_build_array(), 'manifest_checksum', 'abc'
  ));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL register: ok=false (%)', v_res; END IF;
  IF (v_res->>'created')::bool IS DISTINCT FROM TRUE THEN RAISE EXCEPTION 'FAIL register: created != true (%)', v_res; END IF;
  IF (SELECT status FROM core.package_registry WHERE package = '__test_pkg__') <> 'installing'
     THEN RAISE EXCEPTION 'FAIL register: status != installing'; END IF;

  -- (1b) display_name (Install-UX-Phase 6): fehlt in der Nutzlast -> '' (Default), wird bei Re-Register
  --   mit Wert gesetzt und bei Re-Register OHNE Wert bewahrt (COALESCE-Muster wie description).
  IF (SELECT display_name FROM core.package_registry WHERE package = '__test_pkg__') <> ''
     THEN RAISE EXCEPTION 'FAIL register: display_name-Default != leer'; END IF;
  PERFORM core.fn_pkg_register(jsonb_build_object('package', '__test_pkg__', 'display_name', 'Testpaket DE'));
  IF (SELECT display_name FROM core.package_registry WHERE package = '__test_pkg__') <> 'Testpaket DE'
     THEN RAISE EXCEPTION 'FAIL register: display_name nicht gespeichert'; END IF;
  PERFORM core.fn_pkg_register(jsonb_build_object('package', '__test_pkg__', 'version', '1.0.0'));
  IF (SELECT display_name FROM core.package_registry WHERE package = '__test_pkg__') <> 'Testpaket DE'
     THEN RAISE EXCEPTION 'FAIL re-register: display_name ohne Wert ueberschrieben'; END IF;

  -- (2) register erneut (gleiches Paket) = idempotenter Upsert, created=false, Status bleibt.
  v_res := core.fn_pkg_register(jsonb_build_object(
    'package', '__test_pkg__', 'version', '1.1.0', 'core_api', '0.2.0'
  ));
  IF (v_res->>'created')::bool IS DISTINCT FROM FALSE THEN RAISE EXCEPTION 'FAIL re-register: created != false (%)', v_res; END IF;
  IF (SELECT version FROM core.package_registry WHERE package = '__test_pkg__') <> '1.1.0'
     THEN RAISE EXCEPTION 'FAIL re-register: version nicht aktualisiert'; END IF;
  IF (SELECT status FROM core.package_registry WHERE package = '__test_pkg__') <> 'installing'
     THEN RAISE EXCEPTION 'FAIL re-register: status faelschlich geaendert'; END IF;

  -- (3) ungueltiger Status -> CHECK blockt.
  v_blocked := FALSE;
  BEGIN
    UPDATE core.package_registry SET status = '__nope__' WHERE package = '__test_pkg__';
  EXCEPTION WHEN OTHERS THEN v_blocked := TRUE; END;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL: status-CHECK nicht durchgesetzt'; END IF;

  -- (4) set_status: installing -> installed -> active (activated_at wird gesetzt).
  v_res := core.fn_pkg_set_status(jsonb_build_object('package', '__test_pkg__', 'status', 'installed'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL set_status installed (%)', v_res; END IF;
  v_res := core.fn_pkg_set_status(jsonb_build_object('package', '__test_pkg__', 'status', 'active'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL set_status active (%)', v_res; END IF;
  IF (SELECT activated_at FROM core.package_registry WHERE package = '__test_pkg__') IS NULL
     THEN RAISE EXCEPTION 'FAIL set_status: activated_at nicht gesetzt bei ->active'; END IF;

  -- (5) set_status auf unbekanntes Paket -> {ok:false}, KEIN RAISE (korrigierbar).
  v_res := core.fn_pkg_set_status(jsonb_build_object('package', '__does_not_exist__', 'status', 'active'));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL set_status: unbekanntes Paket gab ok=true (%)', v_res; END IF;

  -- (6) check_deps: erfuellte Deps (das aktive __test_pkg__) + core_api kompatibel (min 0.2.0 <= 0.3.0, gleiche major 0).
  v_res := core.fn_pkg_check_deps(jsonb_build_object(
    'package', '__test_pkg2__', 'core_api', '0.2.0', 'requires', jsonb_build_array('__test_pkg__')
  ));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: erfuellte Deps gaben ok=false (%)', v_res; END IF;
  IF NOT (v_res->>'core_api_ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: core_api_ok=false trotz Kompatibilitaet (%)', v_res; END IF;

  -- (7) check_deps: fehlende Dep -> ok=false, missing_deps enthaelt den Namen.
  v_res := core.fn_pkg_check_deps(jsonb_build_object(
    'package', '__test_pkg2__', 'core_api', '0.2.0', 'requires', jsonb_build_array('__absent_pkg__')
  ));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: fehlende Dep gab ok=true (%)', v_res; END IF;
  IF NOT (v_res->'missing_deps' ? '__absent_pkg__') THEN RAISE EXCEPTION 'FAIL check_deps: missing_deps nennt die Dep nicht (%)', v_res; END IF;

  -- (8) check_deps: inkompatible core_api (andere major: braucht >=1.0.0, da ist 0.3.0) -> ok=false, core_api_ok=false.
  v_res := core.fn_pkg_check_deps(jsonb_build_object(
    'package', '__test_pkg2__', 'core_api', '1.0.0', 'requires', jsonb_build_array()
  ));
  IF (v_res->>'core_api_ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: andere major faelschlich kompatibel (%)', v_res; END IF;

  -- (9) check_deps: Dep existiert, ist aber inactive -> ok=false, inactive_deps nennt sie.
  UPDATE core.package_registry SET status = 'inactive' WHERE package = '__test_pkg__';
  v_res := core.fn_pkg_check_deps(jsonb_build_object(
    'package', '__test_pkg2__', 'core_api', '0.2.0', 'requires', jsonb_build_array('__test_pkg__')
  ));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: inaktive Dep gab ok=true (%)', v_res; END IF;
  IF NOT (v_res->'inactive_deps' ? '__test_pkg__') THEN RAISE EXCEPTION 'FAIL check_deps: inactive_deps nennt die Dep nicht (%)', v_res; END IF;

  -- (9b) core_api Laengen-Normalisierung: 2-stellige Core-Version vs. 3-stellige Anforderung.
  --   Postgres-Array-Vergleich ist laengen-sensitiv -> ohne Padding waere '0.3' >= '0.2.0' FALSE.
  UPDATE core.config SET value = '0.3' WHERE category = 'api' AND key = 'core_version';
  v_res := core.fn_pkg_check_deps(jsonb_build_object('package', '__test_pkg2__', 'core_api', '0.2.0', 'requires', jsonb_build_array()));
  IF NOT (v_res->>'core_api_ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: 2-stellige Core-Version (0.3) gegen 0.2.0 faelschlich inkompatibel (%)', v_res; END IF;
  v_res := core.fn_pkg_check_deps(jsonb_build_object('package', '__test_pkg2__', 'core_api', '0.3.1', 'requires', jsonb_build_array()));
  IF (v_res->>'core_api_ok')::bool THEN RAISE EXCEPTION 'FAIL check_deps: 0.3.1 > 0.3.0 faelschlich kompatibel (%)', v_res; END IF;
  UPDATE core.config SET value = '0.3.0' WHERE category = 'api' AND key = 'core_version';

  -- (10) remove: entfernt die Registry-Zeile.
  v_res := core.fn_pkg_remove(jsonb_build_object('package', '__test_pkg__'));
  IF NOT (v_res->>'ok')::bool OR (v_res->>'removed')::bool IS DISTINCT FROM TRUE
     THEN RAISE EXCEPTION 'FAIL remove (%)', v_res; END IF;
  IF EXISTS (SELECT 1 FROM core.package_registry WHERE package = '__test_pkg__')
     THEN RAISE EXCEPTION 'FAIL remove: Zeile noch da'; END IF;

  -- (11) remove auf unbekanntes Paket -> {ok:true, removed:false} (idempotent, kein RAISE).
  v_res := core.fn_pkg_remove(jsonb_build_object('package', '__test_pkg__'));
  IF NOT (v_res->>'ok')::bool OR (v_res->>'removed')::bool IS DISTINCT FROM FALSE
     THEN RAISE EXCEPTION 'FAIL remove (idempotent) (%)', v_res; END IF;

  RAISE NOTICE 'PASS core.package_registry: register/set_status/check_deps/remove + status-CHECK';
END $$;

ROLLBACK;
