-- ============================================================
-- core.fn_sync_role_search_paths (privilegiert — Rollen-search_path DESIRED-STATE-Recompute, B)
--   Setzt den DEFAULT-search_path einer HOST-WEITEN Rolle (core_ro / n8n-Owner) generisch aus dem
--   Ist-Zustand der installierten Pakete: Basis `pg_catalog, agent, core` + ein Tail-Eintrag je Paket,
--   DESSEN SCHEMA PHYSISCH EXISTIERT (`to_regnamespace(package) IS NOT NULL`), sortiert. FULL-REPLACE
--   (EIN `ALTER ROLE … SET search_path = <ganze Liste>`) — kein rolconfig-Parsing, kein Append.
--
--   WARUM Desired-State statt append-if-missing (arch-challenge B1 ADOPT — Terraform/CloudNativePG/
--   Atlas/PG-Wiki-Konsens; internes Muster fn_notify_reconcile/_seed_services/fn_project_persons):
--   idempotent, deterministisch (sortiert, NICHT install-order), SELF-HEALING bei Uninstall
--   (verschwundenes Schema faellt aus dem Pfad, statt als stale Eintrag zu bleiben).
--
--   WARUM Schema-Existenz statt status='active' (Timing): am fn_provision_package_roles-Aufruf
--   (pkg_cmd_install Stage 3) steht das gerade installierende Paket noch auf status='installing',
--   sein Schema existiert aber schon (Stage 2 apply_schema) -> ein status='active'-Filter liesse es
--   STILL aus. `to_regnamespace(package) IS NOT NULL` inkludiert das installierende Paket korrekt und
--   schliesst uninstallierte (Schema gedroppt) sauber aus.
--
--   KONSUMENTEN (Rule of Three, 2 realer): (i) core.fn_provision_package_roles fuer 'core_ro' (neben
--   dem unbedingten core_ro-SELECT-Grant, §4.1 "package declares, host executes"); (ii) apply_schema.sh
--   _emit_pkg_owner_grants fuer die n8n-Owner-Rolle. Basis/Tail-Trennung: der TAIL ist die generische
--   Naht (frueher finance-Hardcode in util_create_core_ro:40); die Basis `pg_catalog, agent, core` ist
--   eine stabile Host-Konstante (core+agent = die Host-Schemata, kein Paket).
--
--   Der core_ro-Tail ist FUNKTIONAL (nicht bloss belt-and-suspenders): agent.monitor/agent.guide fahren
--   unqualifiziertes Frei-SQL (`postgres_select`, `trigger_design.md`) unter core_ro -> ein Paket-Schema
--   MUSS im Pfad stehen. Die ENGEN <pkg>_ro/_rw-Rollen bekommen das NIE (Isolation D10) — diese fn ist
--   ausschliesslich fuer die host-weiten Rollen (core_ro + Owner).
--
--   ROLLENMODELL: ALTER ROLE = Superuser -> laeuft als der aufrufende postgres (apply_schema-Treiber bzw.
--   fn_provision_package_roles, beide Superuser). SECURITY INVOKER (kein Eskalations-Fenster) + search_path-
--   Pin (CVE-2018-1058) + REVOKE PUBLIC (Praezedenz fn_advisor_review_evaluate). RETURNS den gesetzten
--   Pfad (db_test-assertbar). Nicht existente Rolle -> RAISE (Programmierfehler; die Call-Sites uebergeben
--   immer eine existierende Rolle — core_ro guarded via IF EXISTS, Owner existiert immer).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_sync_role_search_paths.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_sync_role_search_paths(p_role text)
RETURNS text
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog
AS $$
DECLARE
    v_tail text;
    v_path text;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_roles WHERE rolname = p_role) THEN
        RAISE EXCEPTION 'core.fn_sync_role_search_paths: role does not exist: %', p_role;
    END IF;

    -- Desired-State-Tail: jedes registrierte Paket (ausser 'core' = in der Basis), dessen Schema PHYSISCH
    -- existiert, deterministisch sortiert + je Name quote_ident (defense in depth; Paketnamen sind
    -- ohnehin ^[a-z][a-z0-9_]*$). Kein Match -> NULL -> leerer Tail.
    SELECT string_agg(quote_ident(package), ', ' ORDER BY package)
      INTO v_tail
      FROM core.package_registry
     WHERE package <> 'core'
       AND to_regnamespace(package) IS NOT NULL;

    v_path := 'pg_catalog, agent, core' || COALESCE(', ' || v_tail, '');

    -- FULL-REPLACE. %s (NICHT %L) fuer die schon-gequotete Liste; %I fuer den Rollennamen.
    EXECUTE format('ALTER ROLE %I SET search_path = %s', p_role, v_path);
    RETURN v_path;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_sync_role_search_paths(text) FROM public;
