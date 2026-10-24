-- ============================================================
-- core.fn_is_free_sql_session() — DIE eine Regel "dieser Aufruf kommt aus einer LLM-Lese-Sitzung"
--   TRUE gdw die LOGIN-Rolle (session_user, unveraendert auch in DEFINER-fns) eine Leserolle *_ro ist (core_ro,
--   context_ro, <pkg>_ro; Namensvertrag D10). Unter diesen Rollen laufen die Frei-SQL-Werkzeuge (postgres_select)
--   -> jedes Argument ist dort LLM-gesteuert. Gebundene Person-Lesefenster (core.fn_advisor_read_plan,
--   career.fn_read_job_matches) nehmen eine chat_id als Argument; Telegram-IDs sind nicht geheim -> aus einer
--   Frei-SQL-Sitzung geben sie fuer per_user-Daten NICHTS heraus (Security-Audit 2026-10, "strikt privat"). Die
--   gebundenen Werkzeuge laufen unter einer Nicht-Frei-SQL-Credential (Haupt-Credential bzw. <pkg>_rw; chat_id build-fix
--   aus dem Start-Node, nie $fromAI).
--   SQL STABLE INVOKER, keine Tabellen.
--   Tests: tests/db/core/test_fn_advisor_read_plan.sql, tests/db/career/test_fn_read_job_matches.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_is_free_sql_session()
RETURNS boolean
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT session_user::text ~ '_ro$';
$$;
