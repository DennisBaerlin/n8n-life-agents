-- ============================================================
-- core.fn_facts_context_allowed(p_name text) -> boolean   (Install-UX-Phase 6 — Naht finance_profile)
--   Welche household-Fakten-Kontexte beschreibbar/zaehlbar sind — EINE Quelle fuer drei Aufrufer: das Gate
--   des household-Zweigs von agent.fn_set_context_facts, der Fakten-Vorfilter von agent.fn_record_learn_candidates
--   und der Aktualitaets-Waechter core.fn_stale_facts_count (Phase A). Ersetzt die feste Liste 'family,
--   finance_profile' (Core kannte ein Paket-Literal) — Geschwister von core.fn_note_context_allowed.
--   TRUE gdw: 'family' (Host-Kontext) ODER der Name ist in core.context_validators registriert, sein Paket ist
--   AKTIV (core.package_registry direkt — das DEFINER-Fenster fn_package_active ist nur an die Paket-Rollen
--   gegrantet, die Aufrufer laufen unter dem Haupt-Cred) und der Kontext ist household-skopiert (core.context_scopes scope
--   'household' bzw. keine Scope-Zeile). per_user-Kontexte (career_profile) laufen ueber den per_user-Zweig von
--   agent.fn_set_context_facts mit Personen-Suffix und sind hier bewusst FALSE. (Kein fn-Name vor einer Klammer
--   in diesem Kopf: contract_lint Check 9 liest Aufrufe textuell — ein Cron ruft diese fn als Vorfilter.)
--   Roh-INVOKER (kein Secret) — die Schreib-Aufrufer laufen unter dem Haupt-RW-Cred, der Waechter unter core_ro
--   (liest nur agent/core-Tabellen, die core_ro sieht).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_facts_context_allowed(p_name text)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = pg_catalog, agent, core
AS $$
    SELECT COALESCE(p_name = 'family', false) OR EXISTS (
        SELECT 1
        FROM core.context_validators v
        JOIN core.package_registry r ON r.package = v.package AND r.status = 'active'
        LEFT JOIN core.context_scopes s ON s.context_name = v.context_name
        WHERE v.context_name = p_name
          AND COALESCE(s.scope, 'household') = 'household'
    );
$$;
