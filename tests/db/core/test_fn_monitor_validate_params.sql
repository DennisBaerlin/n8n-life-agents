-- ============================================================
-- test_fn_monitor_validate_params -- Dispatch an die validate_fn einer Paket-Methode (agent.fn_monitor_validate_params)
--   Gesetz: nie RAISE (auch ein RAISE der Paket-fn wird {ok:false}); Core-Builtins nehmen keine Parameter; nicht
--   verfuegbare Methode -> available:false; Nicht-Objekt als params -> {ok:false}; nur ok:true + spec-Objekt zaehlt.
--   Stub-Paket zz_pkg (in der TX angelegt). BEGIN...ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;

CREATE SCHEMA zz_pkg;
CREATE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN (p->'params'->>'v') ~ '^[0-9.]+$'
              THEN jsonb_build_object('ok', true, 'spec', jsonb_build_object('v', (p->'params'->>'v')::numeric), 'display', 'Wert v')
              ELSE jsonb_build_object('ok', false, 'reason', 'v must be numeric') END $f$;
CREATE FUNCTION zz_pkg.fn_acquire(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT jsonb_build_object('ok', true, 'value', 1) $f$;
INSERT INTO core.package_registry (package, status) VALUES ('zz_pkg', 'active');
INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
VALUES ('zz_vp', 'zz_pkg.fn_acquire', 'zz_pkg.fn_validate', 'zz_pkg');

DO $$
DECLARE
  r jsonb;
BEGIN
  -- Erfolg: spec + display (String) durchgereicht
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": "5"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'available')::boolean IS DISTINCT FROM true
     OR (r->'spec'->>'v')::numeric <> 5 OR r->>'display' <> 'Wert v' THEN
    RAISE EXCEPTION 'FAIL [Erfolg]: %', r;
  END IF;
  RAISE NOTICE 'PASS [Erfolg]: ok, available, spec, display';

  -- Idempotenz-Vertrag: die normalisierte spec als params wieder akzeptiert, unveraendert
  IF agent.fn_monitor_validate_params('zz_vp', r->'spec')->'spec' IS DISTINCT FROM r->'spec' THEN
    RAISE EXCEPTION 'FAIL [Idempotenz]: spec aendert sich beim zweiten Durchlauf';
  END IF;
  RAISE NOTICE 'PASS [Idempotenz]: spec als params ergibt dieselbe spec';

  -- Paket-fn lehnt ab -> Grund der Paket-fn
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": "abc"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'available')::boolean IS DISTINCT FROM true
     OR r->>'reason' <> 'v must be numeric' THEN
    RAISE EXCEPTION 'FAIL [Ablehnung]: %', r;
  END IF;
  RAISE NOTICE 'PASS [Ablehnung]: Grund der validate_fn, available true';

  -- Core-Builtin: kein acquisition_params
  r := agent.fn_monitor_validate_params('sql', '{"x": 1}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'available')::boolean IS DISTINCT FROM true
     OR r->>'reason' NOT LIKE '%is a core method%' THEN
    RAISE EXCEPTION 'FAIL [Builtin]: %', r;
  END IF;
  RAISE NOTICE 'PASS [Builtin]: Core-Methode nimmt keine Parameter';

  -- unbekannte Methode -> available false
  r := agent.fn_monitor_validate_params('zz_nope', '{}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'available')::boolean IS DISTINCT FROM false
     OR r->>'reason' NOT LIKE 'unknown acquisition_method%' THEN
    RAISE EXCEPTION 'FAIL [unbekannt]: %', r;
  END IF;
  RAISE NOTICE 'PASS [unbekannt]: available false';

  -- Paket inaktiv -> available false
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'zz_pkg';
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": "5"}');
  UPDATE core.package_registry SET status = 'active' WHERE package = 'zz_pkg';
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'available')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [inaktiv]: %', r;
  END IF;
  RAISE NOTICE 'PASS [inaktiv]: available false';

  -- Nicht-Objekt als params (Array, String, Zahl, NULL, Build-Sentinel) -> ok false, available true
  FOR r IN SELECT agent.fn_monitor_validate_params('zz_vp', x)
           FROM (VALUES ('[1]'::jsonb), ('"__invalid_json__"'::jsonb), ('5'::jsonb), (NULL::jsonb)) t(x) LOOP
    IF (r->>'ok')::boolean IS DISTINCT FROM false OR (r->>'available')::boolean IS DISTINCT FROM true
       OR r->>'reason' NOT LIKE '%must be a JSON object' THEN
      RAISE EXCEPTION 'FAIL [Nicht-Objekt]: %', r;
    END IF;
  END LOOP;
  RAISE NOTICE 'PASS [Nicht-Objekt]: Array/String/Zahl/NULL -> ok false';

  -- Paket-fn wirft -> wird {ok:false}, kein RAISE nach aussen
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN RAISE EXCEPTION 'kaputt'; END $f$;
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": 1}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT LIKE 'validate_fn of zz_vp failed: kaputt' THEN
    RAISE EXCEPTION 'FAIL [RAISE]: %', r;
  END IF;
  RAISE NOTICE 'PASS [RAISE]: Ausnahme der Paket-fn wird zur Ablehnung';

  -- ok:true ohne spec-Objekt -> abgelehnt
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', true) $f$;
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": 1}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT LIKE '%returned no spec object' THEN
    RAISE EXCEPTION 'FAIL [ohne spec]: %', r;
  END IF;

  -- ok:false ohne reason -> Standardtext; NULL-Rueckgabe -> ebenfalls Ablehnung
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', false) $f$;
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": 1}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' <> 'acquisition_params rejected by zz_vp' THEN
    RAISE EXCEPTION 'FAIL [ohne reason]: %', r;
  END IF;
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT NULL::jsonb $f$;
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": 1}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [NULL-Rueckgabe]: %', r;
  END IF;
  RAISE NOTICE 'PASS [Rueckgabe-Formen]: ohne spec / ohne reason / NULL -> ok false';

  -- display als tpl-Objekt bleibt ein Objekt (Textkatalog), String nur sonst
  CREATE OR REPLACE FUNCTION zz_pkg.fn_validate(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT jsonb_build_object('ok', true, 'spec', jsonb_build_object('v', 1),
                              'display', jsonb_build_object('key', 'zz.display', 'params', jsonb_build_object('v', 1))) $f$;
  r := agent.fn_monitor_validate_params('zz_vp', '{"v": 1}');
  IF jsonb_typeof(r->'display') IS DISTINCT FROM 'object' OR r->'display'->>'key' <> 'zz.display' THEN
    RAISE EXCEPTION 'FAIL [display-Objekt]: %', r;
  END IF;
  RAISE NOTICE 'PASS [display-Objekt]: tpl-Objekt unveraendert';
END $$;
ROLLBACK;
