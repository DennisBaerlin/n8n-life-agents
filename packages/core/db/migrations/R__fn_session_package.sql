-- ============================================================
-- core.fn_session_package() — Paket der Login-Rolle, die eine publizierte Lese-fn gerade aufruft (READ)
--   Die eine Regel fuer die Paket-Grenze der Lesefenster auf agent.*: session_user (bleibt auch in SECURITY DEFINER die
--   Login-Rolle) der Form <pkg>_ro/<pkg>_rw -> '<pkg>'; core_ro/core_rw, Haupt-Credential und Superuser -> NULL (sieht alle
--   Pakete). Aufrufer vergleichen: v_pkg IS NULL OR v_pkg = <Paket der Zeile bzw. Domain>.
--   Keine Eingabe, keine Tabelle. SQL STABLE INVOKER, search_path gepinnt.
--   Konsumenten: core.fn_advisor_open_handoffs, core.fn_advisor_hint_state, core.fn_advisor_handoff_mentions,
--   core.fn_handoff_tasks_read, core.fn_handoff_register.
--   Tests: tests/db/core/test_fn_advisor_open_handoffs.sql (SET SESSION AUTHORIZATION career_ro)
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_session_package()
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT NULLIF(substring(session_user::text from '^([a-z][a-z0-9_]*)_(?:ro|rw)$'), 'core');
$$;
