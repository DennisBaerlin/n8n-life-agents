-- ============================================================
-- fn_household_persons (READ, SECURITY DEFINER — publiziertes Core-Lesefenster, D10)
--   Das einzige Lesefenster der engen Paket-Rollen (finance_ro/finance_rw) auf das projizierte
--   Personen-Read-Model agent.persons. Unter finance_ro (schema-scoped auf
--   finance) erreicht ein Paket agent.* nicht direkt (D10) — fuer die Custodial-Scope-Auswertung
--   braucht die Finance-Schicht aber die Personen-Rolle (role='child' = Kinderdepot):
--     * finance.fn_advisor_review schliesst kind-besessene Assets aus dem FIRE-Pool aus,
--     * finance.parent_cashflow_overview erkennt Eltern->Kind-Transfers ueber die Ziel-Konto-Rolle.
--   Beide joinen dieses Fenster statt agent.persons direkt -> die D10-Isolation bleibt dicht
--   (eine finance-View/fn liest agent.* nie selbst; vgl. fn_advisor_read_plan / fn_monitor_trigger_summary).
--
--   Rueckgabe: eine Zeile je projizierter Person (person_id PK, full_name, role). Haushalts-/Joint-
--   Konten tragen owner_person_id=NULL -> kein Treffer im LEFT JOIN -> role NULL (= bleibt im Pool).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles) = das publizierte Fenster-Muster (fn_advisor_read_plan).
--   Read-only (nur SELECT). agent.persons ist package='core', haushaltsweit, nie domaenen-skopiert ->
--   kein p_domain-Parameter (anders als fn_advisor_read_plan).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_household_persons()
RETURNS TABLE (
    person_id text,
    full_name text,
    role      text
)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, agent, core, pg_temp
AS $$
    SELECT person_id, full_name, role
    FROM agent.persons;
$$;

REVOKE ALL ON FUNCTION core.fn_household_persons() FROM public;
-- EXECUTE-GRANT an die Paket-Rollen erteilt core.fn_provision_package_roles (idempotent,
-- to_regprocedure-geguardet) — hier nur der PUBLIC-REVOKE als Default-Schutz.
