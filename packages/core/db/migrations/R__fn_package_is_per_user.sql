-- ============================================================
-- core.fn_package_is_per_user(p_package) — DIE eine Regel "Onboarding dieses Pakets ist pro Person"
--   TRUE gdw das Paket in core.context_scopes einen per_user-Context deklariert (career). Genutzt von
--   fn_onboarding_status, fn_onboarding_overview, fn_set_onboarding_section und fn_handle_onboarding_cb
--   (vorher je eine Inline-Kopie -> Drift-Risiko zwischen Menue, Gate und Mitglieder-Handler).
--   SQL STABLE INVOKER, liest nur die no-PII-Scope-Registry: unter DEFINER-Aufrufern (status/overview) als
--   deren Owner, unter <pkg>_rw (set_onboarding_section) ueber den bestehenden SELECT-Grant auf
--   core.context_scopes (fn_provision_package_roles). Schema-qualifiziert (Aufrufer pinnen search_path).
--   Tests: indirekt ueber test_fn_onboarding_status/_overview, test_fn_handle_onboarding_cb,
--   test_role_permissions (6, finance_rw/estate_rw).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_package_is_per_user(p_package text)
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT EXISTS (SELECT 1 FROM core.context_scopes cs WHERE cs.package = p_package AND cs.scope = 'per_user');
$$;
