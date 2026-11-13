-- ============================================================
-- fn_sync_role_search_paths (ATOMIC WRITE, privilegiert — Rollen-search_path Desired-State-Recompute)
--   Setzt den Default-search_path einer host-weiten Rolle (core_ro / n8n-Owner) generisch aus dem
--   Ist-Zustand der installierten Pakete: Basis `pg_catalog, agent, core` + ein Tail-Eintrag je Paket,
--   dessen Schema physisch existiert (`to_regnamespace(package) IS NOT NULL`), sortiert. Full-Replace
--   (ein `ALTER ROLE … SET search_path = <ganze Liste>`) — kein rolconfig-Parsing, kein Append.
--   Eingabe: p_role text (existierende Rolle, sonst RAISE). Rueckgabe: text, der gesetzte Pfad.
--
--   Warum Desired-State statt append-if-missing (Terraform/CloudNativePG/Atlas/PG-Wiki-Konsens; internes Muster
--   fn_notify_reconcile/_seed_services/fn_project_persons): idempotent, deterministisch (sortiert, nicht
--   install-order), self-healing bei Uninstall (verschwundenes Schema faellt aus dem Pfad, statt als
--   stale Eintrag zu bleiben).
--
--   Warum Schema-Existenz statt status='active' (Timing): am fn_provision_package_roles-Aufruf
--   (pkg_cmd_install Stage 3) steht das gerade installierende Paket noch auf status='installing',
--   sein Schema existiert aber schon (Stage 2 apply_schema) -> ein status='active'-Filter liesse es
--   still aus. `to_regnamespace(package) IS NOT NULL` inkludiert das installierende Paket korrekt und
--   schliesst uninstallierte (Schema gedroppt) sauber aus.
--
--   Konsumenten: (i) core.fn_provision_package_roles fuer 'core_ro' (neben
--   dem unbedingten core_ro-SELECT-Grant, §4.1 "package declares, host executes"); (ii) apply_schema.sh
--   _emit_pkg_owner_grants fuer die n8n-Owner-Rolle. Basis/Tail-Trennung: der Tail ist die generische
--   Naht; die Basis `pg_catalog, agent, core` ist eine stabile Host-Konstante (core+agent = die
--   Host-Schemata, kein Paket).
--
--   Der core_ro-Tail ist funktional: agent.monitor/agent.guide fahren
--   unqualifiziertes Frei-SQL (`postgres_select`, `trigger_design.md`) unter core_ro -> ein Paket-Schema
--   muss im Pfad stehen. Die engen <pkg>_ro/_rw-Rollen bekommen das nie (Isolation) — diese fn ist
--   ausschliesslich fuer die host-weiten Rollen (core_ro + Owner).
--
--   Rollenmodell: ALTER ROLE = Superuser -> laeuft als der aufrufende postgres (apply_schema-Treiber bzw.
--   fn_provision_package_roles, beide Superuser). SECURITY INVOKER (kein Eskalations-Fenster) + search_path-
--   Pin + REVOKE PUBLIC (wie fn_advisor_review_evaluate). Nicht existente Rolle -> RAISE (Programmierfehler;
--   die Call-Sites uebergeben immer eine existierende Rolle — core_ro guarded via IF EXISTS, Owner existiert immer).
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

    -- Desired-State-Tail: jedes registrierte Paket (ausser 'core' = in der Basis), dessen Schema physisch
    -- existiert, deterministisch sortiert + je Name quote_ident (defense in depth; Paketnamen sind
    -- ohnehin ^[a-z][a-z0-9_]*$). Kein Match -> NULL -> leerer Tail.
    SELECT string_agg(quote_ident(package), ', ' ORDER BY package)
      INTO v_tail
      FROM core.package_registry
     WHERE package <> 'core'
       AND to_regnamespace(package) IS NOT NULL;

    v_path := 'pg_catalog, agent, core' || COALESCE(', ' || v_tail, '');

    -- Full-Replace. %s (nicht %L) fuer die schon-gequotete Liste; %I fuer den Rollennamen.
    EXECUTE format('ALTER ROLE %I SET search_path = %s', p_role, v_path);
    RETURN v_path;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_sync_role_search_paths(text) FROM public;
