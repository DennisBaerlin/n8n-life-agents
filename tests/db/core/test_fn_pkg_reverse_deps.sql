-- tests/db/core/test_fn_pkg_reverse_deps.sql
-- WS-2 (Phase 4a): core.fn_pkg_reverse_deps — Reverse-Dependency-Guard fuer den Uninstall.
--   Liefert die AKTIVEN Pakete, die <pkg> in ihrem `requires` fuehren (der CLI verweigert sonst
--   die Deinstallation). READ-ONLY, kein RAISE; `dependents` ist immer ein jsonb-Array (nie null).
-- db_test hat KEIN seed_data -> der Test registriert die Pakete SELBST (fn_pkg_register/set_status).
-- Self-contained: BEGIN ... ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_res JSONB;
BEGIN
  -- Setup: A (active), B (active, requires [A]), C (inactive, requires [A]).
  PERFORM core.fn_pkg_register(jsonb_build_object('package', '__rd_a__', 'requires', jsonb_build_array()));
  PERFORM core.fn_pkg_set_status(jsonb_build_object('package', '__rd_a__', 'status', 'active'));
  PERFORM core.fn_pkg_register(jsonb_build_object('package', '__rd_b__', 'requires', jsonb_build_array('__rd_a__')));
  PERFORM core.fn_pkg_set_status(jsonb_build_object('package', '__rd_b__', 'status', 'active'));
  PERFORM core.fn_pkg_register(jsonb_build_object('package', '__rd_c__', 'requires', jsonb_build_array('__rd_a__')));
  PERFORM core.fn_pkg_set_status(jsonb_build_object('package', '__rd_c__', 'status', 'inactive'));

  -- (1) reverse_deps(A): nur das AKTIVE B haengt ab; das inaktive C NICHT.
  v_res := core.fn_pkg_reverse_deps(jsonb_build_object('package', '__rd_a__'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL reverse_deps: ok=false (%)', v_res; END IF;
  IF jsonb_typeof(v_res->'dependents') IS DISTINCT FROM 'array'
     THEN RAISE EXCEPTION 'FAIL reverse_deps: dependents ist kein Array (%)', v_res; END IF;
  IF NOT (v_res->'dependents' ? '__rd_b__')
     THEN RAISE EXCEPTION 'FAIL reverse_deps: aktiver Abhaengiger __rd_b__ fehlt (%)', v_res; END IF;
  IF (v_res->'dependents' ? '__rd_c__')
     THEN RAISE EXCEPTION 'FAIL reverse_deps: inaktiver Abhaengiger __rd_c__ faelschlich gelistet (%)', v_res; END IF;

  -- (2) reverse_deps(B): nichts haengt von B ab -> leeres Array (NICHT null).
  v_res := core.fn_pkg_reverse_deps(jsonb_build_object('package', '__rd_b__'));
  IF jsonb_typeof(v_res->'dependents') IS DISTINCT FROM 'array'
     THEN RAISE EXCEPTION 'FAIL reverse_deps [leer]: dependents ist kein Array (%)', v_res; END IF;
  IF jsonb_array_length(v_res->'dependents') <> 0
     THEN RAISE EXCEPTION 'FAIL reverse_deps [leer]: dependents nicht leer (%)', v_res; END IF;

  -- (3) reverse_deps auf unbekanntes Paket -> leeres Array, ok=true (kein RAISE).
  v_res := core.fn_pkg_reverse_deps(jsonb_build_object('package', '__rd_absent__'));
  IF NOT (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL reverse_deps [absent]: ok=false (%)', v_res; END IF;
  IF jsonb_array_length(v_res->'dependents') <> 0
     THEN RAISE EXCEPTION 'FAIL reverse_deps [absent]: dependents nicht leer (%)', v_res; END IF;

  -- (4) leerer package -> {ok:false}.
  v_res := core.fn_pkg_reverse_deps(jsonb_build_object('package', ''));
  IF (v_res->>'ok')::bool THEN RAISE EXCEPTION 'FAIL reverse_deps [empty]: leerer package gab ok=true (%)', v_res; END IF;

  RAISE NOTICE 'PASS core.fn_pkg_reverse_deps: nur aktive Abhaengige, leeres Array statt null, absent/empty-Guards';
END $$;

ROLLBACK;
