-- ============================================================
-- fn_household_persons (PUBLIZIERTE SECURITY-DEFINER-READ-FN — Core-Lesefenster, D10)
--   Das EINZIGE Lesefenster der engen Paket-Rollen (finance_ro/finance_rw) auf das projizierte
--   Personen-Read-Model agent.persons (Multi-Member WS-1). Unter finance_ro (schema-scoped auf
--   finance) erreicht ein Paket agent.* NICHT direkt (D10) — fuer die Custodial-Scope-Auswertung
--   (WS-3a) braucht die Finance-Schicht aber die Personen-ROLLE (role='child' = Kinderdepot):
--     * finance.fn_advisor_review schliesst kind-besessene Assets aus dem FIRE-Pool aus (T2),
--     * finance.parent_cashflow_overview erkennt Eltern->Kind-Transfers ueber die Ziel-Konto-Rolle.
--   Beide joinen dieses Fenster statt agent.persons direkt -> die D10-Isolation bleibt dicht
--   (eine finance-View/fn liest agent.* nie selbst; vgl. fn_advisor_read_plan / fn_monitor_trigger_summary).
--
--   RUECKGABE: eine Zeile je projizierter Person (person_id PK, full_name, role). Haushalts-/Joint-
--   Konten tragen owner_person_id=NULL -> kein Treffer im LEFT JOIN -> role NULL (= bleibt im Pool).
--
--   SECURITY DEFINER + gepinnter search_path + REVOKE ALL FROM PUBLIC + EXECUTE nur an die Paket-Rollen
--   (erteilt in core.fn_provision_package_roles) = das publizierte Fenster-Muster (fn_advisor_read_plan).
--   READ-ONLY (nur SELECT). agent.persons ist package='core', haushaltsweit, nie domaenen-skopiert ->
--   kein p_domain-Parameter (anders als fn_advisor_read_plan).
--   Anwenden via: db_apply.ps1 -File packages\core\db\migrations\R__fn_household_persons.sql
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
