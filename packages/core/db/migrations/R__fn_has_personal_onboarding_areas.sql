-- ============================================================
-- core.fn_has_personal_onboarding_areas() — gibt es persoenliche Onboarding-Bereiche fuer Mitglieder? (2026-10-28)
--   Die EINE Regel hinter dem Knopf "Meine Bereiche": ein aktives Paket (nicht core) ist per_user
--   (core.fn_package_is_per_user) und hat eine <pkg>.onboarding_state-Tabelle. Aufrufer:
--     * core.fn_onboarding_progress_event (members_have_areas der Karte "Es kann losgehen");
--     * agent.fn_confirm_pairing (members_have_areas der Bestaetigung eines spaeter verbundenen Mitglieds).
--   Vorher stand das Praedikat in beiden fns als Kopie (Code-Review 2026-10-28).
--   STABLE/INVOKER, search_path gepinnt; Paketname nur aus core.package_registry, Tabellen-Suffix literal (to_regclass).
--   LANGUAGE plpgsql: ruft das alphabetisch spaetere R__fn_package_is_per_user -> late-bound.
--   Tests: tests/db/core/test_fn_onboarding_progress_event.sql, tests/db/core/test_fn_pairing_challenge.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_has_personal_onboarding_areas()
RETURNS boolean
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN EXISTS (SELECT 1 FROM core.package_registry r
                   WHERE r.status = 'active' AND r.package <> 'core'
                     AND core.fn_package_is_per_user(r.package)
                     AND to_regclass(format('%I.onboarding_state', r.package)) IS NOT NULL);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_has_personal_onboarding_areas() FROM public;
