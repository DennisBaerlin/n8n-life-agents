-- tests/db/core/test_fn_monitor_ro_eval.sql
-- agent.fn_monitor_ro_eval (Security-Audit 2026-10): gespeicherte Monitor-sql-Specs laufen strukturell als core_ro —
-- ohne Ausweg ueber einen eingebetteten Rollenwechsel. Ueber agent.fn_monitor_acquire (den einzigen Aufrufer):
--   1) Eigentuemer = core_ro_eval (NOLOGIN, erbt core_ro), SECURITY DEFINER, EXECUTE nicht an PUBLIC; core_ro darf sie nicht droppen.
--   2) Normale Spec -> Wert, current_user = core_ro_eval.
--   3) Eingebettetes set_config('role','none',true) -> {ok:false} (PG verbietet role in DEFINER-fns).
--   4) Unqualifizierter Name ueber den search_path des Aufrufers wird aufgeloest.
--   5) per_user-Kontextzeilen sind fuer die Spec unsichtbar (RLS auf current_user = core_ro_eval).
--   6) Auf SECURITY INVOKER umgestellt (was core_ro als Eigentuemer koennte) -> Guard -> {ok:false}.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE v jsonb; v_owner text; v_secdef boolean;
BEGIN
  -- 1) Eigentuemer/DEFINER/ACL
  SELECT r.rolname, p.prosecdef INTO v_owner, v_secdef
    FROM pg_proc p JOIN pg_roles r ON r.oid = p.proowner
   WHERE p.oid = 'agent.fn_monitor_ro_eval(text, text)'::regprocedure;
  IF v_owner IS DISTINCT FROM 'core_ro_eval' OR NOT v_secdef THEN
    RAISE EXCEPTION 'FAIL [1] fn_monitor_ro_eval: owner=% secdef=% (erwartet core_ro_eval + DEFINER; util_create_core_ro pruefen)', v_owner, v_secdef;
  END IF;
  IF pg_has_role('core_ro', 'core_ro_eval', 'MEMBER') OR NOT pg_has_role('core_ro_eval', 'core_ro', 'USAGE')
     OR (SELECT rolcanlogin FROM pg_roles WHERE rolname = 'core_ro_eval') THEN
    RAISE EXCEPTION 'FAIL [1] core_ro_eval: core_ro darf nicht Mitglied sein (sonst ALTER/DROP), core_ro_eval muss core_ro erben, NOLOGIN';
  END IF;
  IF has_function_privilege('public', 'agent.fn_monitor_ro_eval(text, text)', 'EXECUTE') THEN
    RAISE EXCEPTION 'FAIL [1] fn_monitor_ro_eval ist fuer PUBLIC ausfuehrbar';
  END IF;
  RAISE NOTICE 'PASS [1] Eigentuemer core_ro_eval (NOLOGIN), DEFINER, kein PUBLIC-EXECUTE';

  -- 2) normale Spec
  v := agent.fn_monitor_acquire('sql', jsonb_build_object('query', 'SELECT CASE WHEN current_user = ''core_ro_eval'' THEN 1 ELSE 0 END'), current_date);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric <> 1 THEN
    RAISE EXCEPTION 'FAIL [2] Spec lief nicht als core_ro_eval: %', v;
  END IF;
  RAISE NOTICE 'PASS [2] Spec laeuft als core_ro_eval';

  -- 3) Ausbruchsversuch ueber set_config('role', ...)
  v := agent.fn_monitor_acquire('sql', jsonb_build_object('query',
         'SELECT CASE WHEN current_user = ''core_ro_eval'' THEN 1 ELSE 0 END FROM (SELECT set_config(''role'', ''none'', true)) x'), current_date);
  IF (v->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [3] eingebettetes set_config(role) wurde nicht abgewiesen: %', v;
  END IF;
  RAISE NOTICE 'PASS [3] set_config(role) aus der Spec heraus abgewiesen (%)', v->>'reason';

  -- 4) unqualifizierter Name ueber den search_path des Aufrufers
  CREATE SCHEMA zz_mon;
  CREATE TABLE zz_mon.zz_val (v numeric);
  INSERT INTO zz_mon.zz_val VALUES (42);
  GRANT USAGE ON SCHEMA zz_mon TO core_ro;
  GRANT SELECT ON zz_mon.zz_val TO core_ro;
  PERFORM set_config('search_path', 'zz_mon, public, agent, core', true);
  v := agent.fn_monitor_acquire('sql', jsonb_build_object('query', 'SELECT max(v) FROM zz_val'), current_date);
  PERFORM set_config('search_path', '"$user", public', true);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric <> 42 THEN
    RAISE EXCEPTION 'FAIL [4] unqualifizierter Name nicht ueber den Aufrufer-Pfad aufgeloest: %', v;
  END IF;
  RAISE NOTICE 'PASS [4] Aufrufer-search_path fuer unqualifizierte Namen';

  -- 5) per_user-Zeilen unsichtbar
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__mon_pu__', 'per_user', 'own_user_only', 'core')
  ON CONFLICT (context_name) DO UPDATE SET scope = 'per_user';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content)
  VALUES ('__mon_pu____x', 'fix', NULL, 'lazy', 'privat');
  v := agent.fn_monitor_acquire('sql', jsonb_build_object('query',
         'SELECT count(*) FROM agent.core_contexts WHERE name = ''__mon_pu____x'''), current_date);
  IF (v->>'ok')::boolean IS DISTINCT FROM true OR (v->>'value')::numeric <> 0 THEN
    RAISE EXCEPTION 'FAIL [5] Spec sieht eine per_user-Zeile: %', v;
  END IF;
  RAISE NOTICE 'PASS [5] per_user-Zeilen fuer Monitor-Specs unsichtbar';

  -- 6) INVOKER-Umstellung -> Guard
  ALTER FUNCTION agent.fn_monitor_ro_eval(text, text) SECURITY INVOKER;
  v := agent.fn_monitor_acquire('sql', jsonb_build_object('query', 'SELECT 1'), current_date);
  IF (v->>'ok')::boolean IS DISTINCT FROM false OR position('core_ro_eval' in v->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL [6] INVOKER-Umstellung lief ohne Guard: %', v;
  END IF;
  RAISE NOTICE 'PASS [6] INVOKER-Umstellung -> Guard (fail-closed)';
END $$;
ROLLBACK;
