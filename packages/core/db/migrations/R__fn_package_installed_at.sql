-- ============================================================
-- fn_package_installed_at (READ-ONLY, SECURITY DEFINER)
--   Installationszeit eines Pakets aus core.package_registry (installed_at); unbekanntes Paket / NULL -> NULL.
--   Eingabe: p_package text (Paketschluessel). Rueckgabe: timestamptz.
--   Zweck: Anker fuer "seit der Installation noch nie ..."-Pruefungen eines Pakets unter seiner engen Rolle
--   (finance.fn_fx_feed_gap: noch nie ein Wechselkurs abgerufen). Muster und Grund wie core.fn_package_active: die
--   enge Paket-Rolle hat kein SELECT auf core.package_registry, diese fn gibt nur den Zeitstempel heraus.
--   Seiteneffekte: keine. EXECUTE-Grant an <pkg>_rw setzt core.fn_provision_package_roles (to_regprocedure-guarded).
--   Tests: tests/db/finance/test_fn_fx_feed_gap.sql (Rollen-Perspektive finance_rw), tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_package_installed_at(p_package text)
RETURNS timestamptz
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT installed_at FROM core.package_registry WHERE package = p_package;
$$;

REVOKE ALL ON FUNCTION core.fn_package_installed_at(text) FROM public;
