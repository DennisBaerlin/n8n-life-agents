-- ============================================================
-- core.fn_household_plan_active(p_domain) — der AKTIVE Haushalts-Plan einer Berater-Domaene (Plan teilen, 2026-10-28)
--   Die EINE Adresse fuer "gibt es einen teilbaren Haushalts-Plan, welche Version": Domain-Regel core.fn_household_plan_domain
--   (plan_step, Paket aktiv, Scope household) und eine active-Zeile mit person_id NULL. Persoenliche Plaene (per_user, career) liefern nie eine Zeile.
--   Leser: core.fn_plan_adult_recipients/_share_preview/_share_targets, core.fn_handle_plan_cb, agent.fn_record_plan_wish.
--   RUECKGABE: 0 oder 1 Zeile (plan_id, version, change_summary, change_summary_lang, package).
--   STABLE, SECURITY DEFINER (liest agent.advisor_plans mit RLS + core.*), search_path gepinnt; EXECUTE nur ueber die
--   DEFINER-/Host-Aufrufer (REVOKE PUBLIC). LANGUAGE plpgsql: ruft das alphabetisch spaetere R__fn_household_plan_domain.
--   Tests: tests/db/core/test_fn_plan_share_targets.sql, tests/db/core/test_fn_record_plan_wish.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_household_plan_active(p_domain text)
RETURNS TABLE (plan_id int, version int, change_summary text, change_summary_lang text, package text)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF NOT core.fn_household_plan_domain(p_domain) THEN
        RETURN;
    END IF;
    RETURN QUERY
    SELECT ap.id, ap.version, ap.change_summary, ap.change_summary_lang, a.package
    FROM core.advisors a
    JOIN agent.advisor_plans ap ON ap.domain = a.domain AND ap.person_id IS NULL AND ap.status = 'active'
    WHERE a.domain = p_domain;
END;
$$;

REVOKE ALL ON FUNCTION core.fn_household_plan_active(text) FROM public;
