-- ============================================================
-- core.fn_household_plan_domain(p_domain) — ist die Domain eine teilbare Haushalts-Plan-Domain? (Plan teilen, 2026-10-28)
--   Die EINE Regel: core.advisors-Zeile mit plan_step=true, Paket aktiv (core.package_registry), Scope des plan_context
--   household (core.context_scopes; ohne Zeile = household). Persoenliche Plaene (per_user, career) -> false.
--   Leser: core.fn_household_plan_active (+ aktive Version) und core.fn_handle_plan_cb (Verben share/explain/wish:
--   "Domain unbekannt" vs. "kein aktiver Plan" unterscheiden). STABLE, SECURITY DEFINER, search_path gepinnt.
--   Tests: tests/db/core/test_fn_handle_plan_cb.sql, tests/db/core/test_fn_plan_share_targets.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_household_plan_domain(p_domain text)
RETURNS boolean
LANGUAGE sql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (
        SELECT 1 FROM core.advisors a
        JOIN core.package_registry pr ON pr.package = a.package AND pr.status = 'active'
        WHERE a.domain = p_domain AND a.plan_step
          AND COALESCE((SELECT cs.scope FROM core.context_scopes cs WHERE cs.context_name = a.plan_context), 'household') = 'household');
$$;

REVOKE ALL ON FUNCTION core.fn_household_plan_domain(text) FROM public;
