-- tests/db/core/test_fn_config_get.sql
-- WS4a: core.fn_config_get(package, category, key) -> text (generisches read-all-Config-Fenster)
--   + die Cron-Gate-Expression core.fn_package_active(p) AND COALESCE(fn_config_get(p,'cron_enable',c)='true', false).
--   Muster: BEGIN…ROLLBACK, eigene Zeilen seeden (db_test hat kein seed_data). RAISE EXCEPTION 'FAIL …' = rot.
BEGIN;

-- ---------- fn_config_get: read-all + fehlend -> NULL ----------
DO $$
BEGIN
  INSERT INTO core.config (category, key, value, package) VALUES
    ('cron_enable', '__t_always__', 'true',  '__pkgA__'),
    ('cron_enable', '__t_optin__',  'false', '__pkgA__'),
    ('schedule',    '__t_sched__',  '0 6 * * *', '__pkgB__');   -- non-model category (kein Model-Enum-Trigger)

  IF core.fn_config_get('__pkgA__','cron_enable','__t_always__') IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL [read own pkg value]'; END IF;
  -- read-all: jede Rolle/jeder Aufruf liest JEDE Zeile, egal welches Paket (hier nur Wert-Read, Rolle s. VF3)
  IF core.fn_config_get('__pkgB__','schedule','__t_sched__') IS DISTINCT FROM '0 6 * * *' THEN
    RAISE EXCEPTION 'FAIL [read other pkg value]'; END IF;
  -- fehlende Zeile -> NULL (treibt fail-closed im Gate)
  IF core.fn_config_get('__pkgA__','cron_enable','__missing__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [missing -> not NULL]'; END IF;
  IF core.fn_config_get('__nope__','cron_enable','__t_always__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [wrong package -> not NULL]'; END IF;

  RAISE NOTICE 'PASS core.fn_config_get [read-all + missing->NULL]';
END $$;

-- ---------- Gate-Expression-Matrix: active × (missing/false/true) × inactive ----------
DO $$
DECLARE
  v_pkg text := '__gate_pkg__';
  v boolean;
BEGIN
  INSERT INTO core.package_registry (package, version, status)
  VALUES (v_pkg, '1.0.0', 'active') ON CONFLICT (package) DO UPDATE SET status='active';

  -- aktiv + fehlende Flag-Zeile -> fail-closed -> FALSE
  v := core.fn_package_active(v_pkg) AND COALESCE(core.fn_config_get(v_pkg,'cron_enable','c1')='true', false);
  IF v THEN RAISE EXCEPTION 'FAIL [active + missing -> true]'; END IF;

  -- aktiv + 'false' -> FALSE
  INSERT INTO core.config (category,key,value,package) VALUES ('cron_enable','c1','false',v_pkg);
  v := core.fn_package_active(v_pkg) AND COALESCE(core.fn_config_get(v_pkg,'cron_enable','c1')='true', false);
  IF v THEN RAISE EXCEPTION 'FAIL [active + false -> true]'; END IF;

  -- aktiv + 'true' -> TRUE
  UPDATE core.config SET value='true' WHERE category='cron_enable' AND key='c1';
  v := core.fn_package_active(v_pkg) AND COALESCE(core.fn_config_get(v_pkg,'cron_enable','c1')='true', false);
  IF NOT v THEN RAISE EXCEPTION 'FAIL [active + true -> false]'; END IF;

  -- inaktiv + 'true' -> FALSE (Paket-Aus schlaegt den Flag)
  UPDATE core.package_registry SET status='inactive' WHERE package=v_pkg;
  v := core.fn_package_active(v_pkg) AND COALESCE(core.fn_config_get(v_pkg,'cron_enable','c1')='true', false);
  IF v THEN RAISE EXCEPTION 'FAIL [inactive + true -> true]'; END IF;

  RAISE NOTICE 'PASS Gate-Expression [active×flag×inactive, fail-closed]';
END $$;

-- ---------- VF3 (D10): finance_ro liest ueber das DEFINER-Fenster, NICHT direkt core.config ----------
DO $$
DECLARE v_val text; v_blocked boolean := false;
BEGIN
  INSERT INTO core.config (category,key,value,package) VALUES ('cron_enable','__vf3__','true','finance');

  SET LOCAL ROLE finance_ro;
  v_val := core.fn_config_get('finance','cron_enable','__vf3__');   -- EXECUTE-Grant greift
  BEGIN
    PERFORM 1 FROM core.config WHERE category='cron_enable' AND key='__vf3__';  -- muss scheitern (Isolation)
  EXCEPTION WHEN insufficient_privilege THEN v_blocked := true;
  END;
  RESET ROLE;

  IF v_val IS DISTINCT FROM 'true' THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro konnte fn_config_get nicht lesen]: %', v_val; END IF;
  IF NOT v_blocked THEN
    RAISE EXCEPTION 'FAIL VF3 [finance_ro hat direkten SELECT auf core.config]'; END IF;

  RAISE NOTICE 'PASS VF3 [finance_ro liest Config nur ueber das publizierte DEFINER-Fenster]';
END $$;

ROLLBACK;
