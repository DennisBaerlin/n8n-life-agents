-- tests/db/core/test_fn_monitor_probe.sql
-- Testet fn_monitor_probe: der read-only Test-Abruf VOR dem HITL-Gate (create/set-Tools).
-- Vertrag: fuehrt die Beschaffung exakt wie der Cron aus — sql: EXECUTE unter
--   SET LOCAL ROLE core_ro (Scalar-Subquery-Wrap, Shape-Guard); Paket-Methode (Phase B): Registry-Dispatch
--   ueber validate_fn + acquire_fn (hier eine Test-Methode zz_test mit Stub-fns — die echte finance-fx_rate
--   testet tests/db/finance/test_fn_monitor_acquire_fx_rate.sql); web_search: nimmt die im Workflow beschaffte
--   Observation entgegen; none: ok ohne Wert. Danach Validierungs-Kaskade
--   (fn_validate_observation). KEIN Write (Probe laeuft vor dem Gate).
--   Eingabe jsonb: acquisition_method, acquisition_sql|acquisition_params|observation,
--     expected_unit, min_plausible, max_plausible, as_of (Test-Injektion).
--   Rueckgabe: {ok, value, unit, as_of, source_url, reason, display?}
BEGIN;

-- Test-Methode zz_test (Stub-Paket zz_pkg): validate verlangt params.v numerisch, acquire liefert spec.v.
CREATE SCHEMA zz_pkg;
CREATE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN (p->'params'->>'v') ~ '^[0-9.]+$'
              THEN jsonb_build_object('ok', true, 'spec', jsonb_build_object('v', (p->'params'->>'v')::numeric),
                                      'display', 'Testwert: ' || (p->'params'->>'v'))
              ELSE jsonb_build_object('ok', false, 'reason', 'v must be numeric') END $f$;
CREATE FUNCTION zz_pkg.fn_acquire(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('ok', true, 'value', (p->'spec'->>'v')::numeric, 'as_of', p->>'as_of', 'source_url', 'zz') $f$;
INSERT INTO core.package_registry (package, status) VALUES ('zz_pkg', 'active');
INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
VALUES ('zz_test', 'zz_pkg.fn_acquire', 'zz_pkg.fn_validate', 'zz_pkg');

DO $$
DECLARE
  v JSONB;
BEGIN

  -- TEST 1: sql happy path — Wert kommt, Rolle ist core_ro (current_user-Echo beweist
  -- den SET LOCAL ROLE-Switch strukturell; B3: core_ro = Core-Host-Leserolle agent+core+finance)
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'sql',
    'acquisition_sql', 'SELECT 42.5'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric IS DISTINCT FROM 42.5 THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [sql happy]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [sql liefert Wert]';

  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'sql',
    'acquisition_sql', 'SELECT CASE WHEN current_user = ''core_ro_eval'' THEN 1 ELSE 0 END'
  ));
  IF (v->>'value')::numeric IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [sql role]: EXECUTE laeuft NICHT unter core_ro, got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [sql laeuft unter core_ro]';

  -- TEST 2: sql Shape-Guard — non-SELECT und Multi-Statement abgelehnt (kein EXECUTE)
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'sql',
    'acquisition_sql', 'DELETE FROM agent.monitor_triggers'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [sql non-select]: erwartet ok=false, got %', v;
  END IF;
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'sql',
    'acquisition_sql', 'SELECT 1; DROP TABLE agent.monitor_triggers'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [sql multi-statement]: erwartet ok=false, got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [sql Shape-Guard]';

  -- TEST 3: sql Mehrzeilen-/Mehrspalten-Ergebnis -> deterministischer Fehlerpfad
  -- (Scalar-Subquery-Wrap: >1 Zeile/Spalte bricht kontrolliert)
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'sql',
    'acquisition_sql', 'SELECT x FROM (VALUES (1),(2)) t(x)'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [sql >1 row]: erwartet ok=false, got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [sql >1 Zeile -> Fehlerpfad]';

  -- TEST 4: Paket-Methode (Registry-Dispatch) — gueltige params -> Wert + display; ungueltige /
  -- Nicht-Objekt (Build-Sentinel) / unbekannte Methode / inaktives Paket -> {ok:false}, nie RAISE
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'zz_test', 'acquisition_params', jsonb_build_object('v', 7.5), 'as_of', '2026-06-10'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric IS DISTINCT FROM 7.5
     OR v->>'display' IS DISTINCT FROM 'Testwert: 7.5' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [pkg method happy]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [Paket-Methode: Wert + Bestaetigungszeile]';

  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'zz_test', 'acquisition_params', jsonb_build_object('v', 'abc')));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%numeric%' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [pkg method invalid params]: got %', v;
  END IF;
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'zz_test', 'acquisition_params', '__invalid_json__'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%JSON object%' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [pkg method sentinel]: got %', v;
  END IF;
  v := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'zz_nope'));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%unknown acquisition_method%' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [unknown method]: got %', v;
  END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'zz_pkg';
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'zz_test', 'acquisition_params', jsonb_build_object('v', 1)));
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR v->>'reason' NOT ILIKE '%not active%' THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [pkg inactive]: got %', v;
  END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'zz_pkg';
  RAISE NOTICE 'PASS fn_monitor_probe [Paket-Methode ungueltig/Sentinel/unbekannt/inaktiv -> {ok:false}]';

  -- TEST 5: web_search — Workflow liefert die Observation, Probe validiert sie
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'web_search',
    'expected_unit', 'USD/oz',
    'min_plausible', 1000, 'max_plausible', 10000,
    'observation', jsonb_build_object('ok', true, 'value', 4188.5, 'unit', 'USD/oz',
                                      'as_of', '2026-06-09', 'source_url', 'https://example.com')
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric IS DISTINCT FROM 4188.5 THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [web clean]: got %', v;
  END IF;
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'web_search',
    'expected_unit', 'USD/oz',
    'observation', jsonb_build_object('ok', true, 'value', 120, 'unit', 'EUR/g')
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [web unit mismatch]: erwartet ok=false, got %', v;
  END IF;
  v := agent.fn_monitor_probe(jsonb_build_object(
    'acquisition_method', 'web_search',
    'expected_unit', 'USD/oz'
  ));
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [web ohne observation]: erwartet ok=false, got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [web: validiert die Workflow-Observation]';

  -- TEST 6: none — reiner Reminder, ok ohne Wert
  v := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'none'));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_monitor_probe [none]: got %', v;
  END IF;
  RAISE NOTICE 'PASS fn_monitor_probe [none ok]';

END $$;

ROLLBACK;
