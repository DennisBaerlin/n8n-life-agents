-- tests/db/cross/test_role_table_grants.sql
-- Grenzpruefung der Paket-Rollen (Rollen-Tests Stufe 2, Teil C): je Paket-Schema mit <pkg>_rw und <pkg>_ro (core.fn_provision_package_roles)
--   (a) <pkg>_rw hat SELECT/INSERT/UPDATE/DELETE auf jeder Tabelle und View des Schemas und USAGE+SELECT auf jeder Sequenz,
--       <pkg>_ro hat SELECT auf jeder Tabelle und View;
--   (b) ALTER DEFAULT PRIVILEGES greift: eine neue Tabelle samt Sequenz im Schema ist ohne weiteren Grant fuer beide benutzbar;
--   (c) <pkg>_rw/_ro haben auf Tabellen anderer Schemas (agent, core, Nachbar-Pakete) kein Schreibrecht und kein Leserecht ausser der
--       Ausnahme unten (Writes dorthin laufen nur ueber DEFINER-fns, deren Aufrufbarkeit test_role_catalog_exec.sql prueft).
-- Ausnahme in (c): <pkg>_rw liest core.context_scopes (core.fn_set_onboarding_section ist INVOKER und liest dort den Scope; Grant in
-- R__fn_provision_package_roles.sql). Jede weitere Fremd-Tabelle mit Leserecht muss hier mit Grund eingetragen werden.
-- Ein fehlendes Tabellen-/Sequenzrecht stuende zur Laufzeit als "permission denied" in der Bestaetigungskarte; db_test laeuft als Superuser.
BEGIN;

DO $t$
DECLARE
  v_pkg    text;
  v_rw     text;
  v_ro     text;
  r        record;
  v_bad    text[] := '{}';
  v_pkgs   int := 0;
  v_obj    int := 0;
  v_tab    oid;
  v_seq    oid;
BEGIN
  FOR v_pkg IN
    SELECT n.nspname FROM pg_namespace AS n
    WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = n.nspname || '_rw')
      AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname = n.nspname || '_ro')
    ORDER BY 1
  LOOP
    v_pkgs := v_pkgs + 1;
    v_rw := v_pkg || '_rw';
    v_ro := v_pkg || '_ro';
    -- (a) alle vorhandenen Objekte
    FOR r IN
      SELECT c.oid, c.relname, c.relkind FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE n.nspname = v_pkg AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    LOOP
      v_obj := v_obj + 1;
      IF r.relkind = 'S' THEN
        IF NOT has_sequence_privilege(v_rw, r.oid, 'USAGE') OR NOT has_sequence_privilege(v_rw, r.oid, 'SELECT') THEN
          v_bad := v_bad || (v_rw || ' hat nicht USAGE+SELECT auf die Sequenz ' || v_pkg || '.' || r.relname);
        END IF;
      ELSE
        IF r.relkind IN ('r', 'p') THEN
          IF NOT (has_table_privilege(v_rw, r.oid, 'SELECT') AND has_table_privilege(v_rw, r.oid, 'INSERT')
                  AND has_table_privilege(v_rw, r.oid, 'UPDATE') AND has_table_privilege(v_rw, r.oid, 'DELETE')) THEN
            v_bad := v_bad || (v_rw || ' hat nicht SELECT/INSERT/UPDATE/DELETE auf ' || v_pkg || '.' || r.relname);
          END IF;
        ELSIF NOT has_table_privilege(v_rw, r.oid, 'SELECT') THEN
          v_bad := v_bad || (v_rw || ' hat kein SELECT auf die View ' || v_pkg || '.' || r.relname);
        END IF;
        IF NOT has_table_privilege(v_ro, r.oid, 'SELECT') THEN
          v_bad := v_bad || (v_ro || ' hat kein SELECT auf ' || v_pkg || '.' || r.relname);
        END IF;
      END IF;
    END LOOP;
    -- (b) Default-Privilegien: neue Tabelle + Sequenz im Schema
    EXECUTE format('CREATE TABLE %I.rp_grant_probe (id serial PRIMARY KEY, v text)', v_pkg);
    v_tab := to_regclass(format('%I.rp_grant_probe', v_pkg));
    v_seq := to_regclass(format('%I.rp_grant_probe_id_seq', v_pkg));
    IF NOT (has_table_privilege(v_rw, v_tab, 'SELECT') AND has_table_privilege(v_rw, v_tab, 'INSERT')
            AND has_table_privilege(v_rw, v_tab, 'UPDATE') AND has_table_privilege(v_rw, v_tab, 'DELETE')) THEN
      v_bad := v_bad || (v_rw || ': neue Tabelle in ' || v_pkg || ' ohne CRUD-Recht (ALTER DEFAULT PRIVILEGES fehlt)');
    END IF;
    IF NOT has_sequence_privilege(v_rw, v_seq, 'USAGE') THEN
      v_bad := v_bad || (v_rw || ': neue Sequenz in ' || v_pkg || ' ohne USAGE (ALTER DEFAULT PRIVILEGES fehlt)');
    END IF;
    IF NOT has_table_privilege(v_ro, v_tab, 'SELECT') THEN
      v_bad := v_bad || (v_ro || ': neue Tabelle in ' || v_pkg || ' ohne SELECT (ALTER DEFAULT PRIVILEGES fehlt)');
    END IF;
    EXECUTE format('DROP TABLE %I.rp_grant_probe', v_pkg);
    -- (c) kein Tabellenrecht ausserhalb des eigenen Schemas
    FOR r IN
      SELECT n.nspname, c.relname,
             has_table_privilege(v_rw, c.oid, 'SELECT') AS rw_sel, has_table_privilege(v_rw, c.oid, 'INSERT, UPDATE, DELETE') AS rw_wr,
             has_table_privilege(v_ro, c.oid, 'SELECT') AS ro_sel, has_table_privilege(v_ro, c.oid, 'INSERT, UPDATE, DELETE') AS ro_wr
      FROM pg_class AS c JOIN pg_namespace AS n ON n.oid = c.relnamespace
      WHERE c.relkind IN ('r', 'p', 'v', 'm') AND n.nspname <> v_pkg
        AND n.nspname IN (SELECT nspname FROM pg_namespace WHERE nspname !~ '^(pg_|information_schema)')
        AND n.nspname <> 'public'
    LOOP
      IF r.rw_wr THEN v_bad := v_bad || (v_rw || ' hat ein Schreibrecht auf ' || r.nspname || '.' || r.relname || ' (fremdes Schema)'); END IF;
      IF r.ro_wr THEN v_bad := v_bad || (v_ro || ' hat ein Schreibrecht auf ' || r.nspname || '.' || r.relname || ' (fremdes Schema)'); END IF;
      IF r.rw_sel AND (r.nspname || '.' || r.relname) <> 'core.context_scopes' THEN
        v_bad := v_bad || (v_rw || ' hat ein Leserecht auf ' || r.nspname || '.' || r.relname || ' (fremdes Schema)');
      END IF;
      IF r.ro_sel THEN v_bad := v_bad || (v_ro || ' hat ein Leserecht auf ' || r.nspname || '.' || r.relname || ' (fremdes Schema)'); END IF;
    END LOOP;
  END LOOP;
  IF v_pkgs < 3 THEN
    RAISE EXCEPTION 'FAIL: nur % Paket-Schemas mit _rw/_ro gefunden (erwartet >= 3: finance, estate, career, paperless)', v_pkgs;
  END IF;
  IF cardinality(v_bad) > 0 THEN
    RAISE EXCEPTION 'FAIL: % Befund(e) in % Paket-Schemas:%', cardinality(v_bad), v_pkgs, E'\n' || array_to_string(v_bad, E'\n');
  END IF;
  RAISE NOTICE 'PASS test_role_table_grants: % Paket-Schemas, % Objekte, Default-Privilegien greifen', v_pkgs, v_obj;
END
$t$;

ROLLBACK;
