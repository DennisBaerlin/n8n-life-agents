-- ============================================================
-- V022 — Alt-Grants der Paket-Rollen auf agent/core zuruecknehmen (Phase B, D10-Hygiene)
--   Die retirte breite Leserolle finance_ro (util_create_finance_ro, entfernt in 9fbba52) bekam USAGE auf
--   agent+core, SELECT auf alle Tabellen + DEFAULT PRIVILEGES fuer kuenftige Tabellen; nichts im Repo hat das
--   je zurueckgenommen — die vielen `REVOKE ... FROM finance_ro` in den Core-fns waren der Ersatz-Zaun. Diese
--   Migration nimmt die Altlast GENERISCH fuer JEDE Paket-Rolle (<pkg>_ro/<pkg>_rw, Paket aus
--   core.package_registry ∪ core.schema_version) zurueck: Schema agent komplett, Tabellen/Sequenzen in agent
--   und core, Default-Privileges in agent/core/global. EXECUTE auf Core-fns bleibt (die publizierten Fenster
--   vergibt core.fn_provision_package_roles, die alte Rolle bekam nie EXECUTE). fn_provision_package_roles
--   (laeuft bei jedem Paket-Install/-Update NACH dieser Schema-Phase) vergibt die legitimen Core-Grants
--   (z. B. SELECT core.context_scopes an <pkg>_rw) neu. Danach sind die finance_ro-REVOKEs der Core-fns
--   redundant (REVOKE ... FROM public ist die echte Kontrolle) und entfallen.
--   Frische DB: keine Paket-Rollen -> No-op. Idempotent (REVOKE ohne Grant ist ein No-op).
-- ============================================================
DO $$
DECLARE
    v_pkg  text;
    v_role text;
    r      record;
BEGIN
    FOR v_pkg IN
        SELECT DISTINCT s.package FROM (
            SELECT package FROM core.package_registry
            UNION SELECT package FROM core.schema_version) s
        WHERE s.package <> 'core' AND s.package ~ '^[a-z][a-z0-9_]*$'
    LOOP
        FOREACH v_role IN ARRAY ARRAY[v_pkg || '_ro', v_pkg || '_rw'] LOOP
            CONTINUE WHEN NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role);
            EXECUTE format('REVOKE ALL ON SCHEMA agent FROM %I', v_role);
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA agent FROM %I', v_role);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA agent FROM %I', v_role);
            EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA core FROM %I', v_role);
            EXECUTE format('REVOKE ALL ON ALL SEQUENCES IN SCHEMA core FROM %I', v_role);
            FOR r IN
                SELECT d.defaclrole::regrole::text AS grantor, n.nspname AS nsp, d.defaclobjtype AS objtype
                  FROM pg_default_acl d
                  LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
                 WHERE (n.nspname IN ('agent', 'core') OR d.defaclnamespace = 0)
                   AND EXISTS (SELECT 1 FROM aclexplode(d.defaclacl) a
                                WHERE a.grantee = (SELECT oid FROM pg_roles WHERE rolname = v_role))
            LOOP
                EXECUTE format('ALTER DEFAULT PRIVILEGES FOR ROLE %s %s REVOKE ALL ON %s FROM %I',
                    r.grantor,
                    CASE WHEN r.nsp IS NULL THEN '' ELSE format('IN SCHEMA %I', r.nsp) END,
                    CASE r.objtype WHEN 'r' THEN 'TABLES' WHEN 'S' THEN 'SEQUENCES' WHEN 'f' THEN 'FUNCTIONS'
                                   WHEN 'T' THEN 'TYPES' ELSE 'SCHEMAS' END,
                    v_role);
            END LOOP;
        END LOOP;
    END LOOP;
END $$;
