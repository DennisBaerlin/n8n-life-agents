-- ============================================================
-- fn_menu_refresh_request (WRITE)
--   Legt einen Menue-Auftrag an (core.menu_refresh), damit der Knopf „Uebersicht“ folgt; keine Eingabe.
--   SECURITY DEFINER: core.fn_set_onboarding_section laeuft unter den engen <pkg>_rw-Rollen, die core.menu_refresh nicht
--   schreiben duerfen. EXECUTE je Paket-Rolle in core.fn_provision_package_roles. Rueckgabe: void.
--   Tests: tests/db/core/test_fn_app_button_state.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_menu_refresh_request()
RETURNS void
LANGUAGE sql
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    INSERT INTO core.menu_refresh (id, requested_gen, requested_at) VALUES (TRUE, 1, now())
    ON CONFLICT (id) DO UPDATE SET requested_gen = core.menu_refresh.requested_gen + 1, requested_at = now();
$$;
REVOKE ALL ON FUNCTION core.fn_menu_refresh_request() FROM public;
