-- ============================================================
-- career.fn_read_job_matches(chat_id, limit) — gebundenes Lesefenster der EIGENEN Job-Treffer (read-only)
--   career.job_matches ist person-privat (person_id NOT NULL in einem per_user-Paket) -> fuer die Frei-SQL-Rollen
--   career_ro/core_ro gesperrt (core.fn_provision_package_roles, Security-Audit 2026-10, Owner "strikt privat").
--   Der career_advisor liest seine Treffer ueber das Werkzeug read_job_matches: Credential career_rw (keine
--   Frei-SQL-Rolle), chat_id build-fix aus dem Start-Node (nie $fromAI). Person aus agent.fn_resolve_sender
--   (fail-closed: unaufgeloest -> leer); ein Aufruf aus einer Frei-SQL-Sitzung (core.fn_is_free_sql_session) -> leer
--   (Defense in depth: die *_ro-Rollen haben ohnehin kein EXECUTE).
--   Neueste Bewertung zuerst (feedback_at DESC NULLS LAST, dann created_at DESC) -> die "zuletzt bewertete Stelle"
--   fuer den Freitext-Grund-Loop ist die erste Zeile mit feedback_at. p_limit: Default 20, gekappt auf 1..100.
--   SECURITY DEFINER + gepinnter search_path + REVOKE PUBLIC; EXECUTE bekommt nur career_rw (Bulk-Grant aller
--   career-fns in core.fn_provision_package_roles; der INVOKER-Bulk-Grant an career_ro laesst DEFINER-fns aus).
--   Tests: tests/db/career/test_fn_read_job_matches.sql, tests/db/cross/test_role_permissions.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_read_job_matches(p_chat_id text, p_limit int DEFAULT 20)
RETURNS TABLE (
    id             bigint,
    source         text,
    board          text,
    external_id    text,
    title          text,
    employer       text,
    location       text,
    url            text,
    score          smallint,
    is_serendipity boolean,
    status         text,
    feedback_at    timestamptz,
    created_at     timestamptz
)
LANGUAGE plpgsql STABLE
SECURITY DEFINER
SET search_path = pg_catalog, career, agent, core, pg_temp
AS $$
DECLARE
    v_pid TEXT;
BEGIN
    IF core.fn_is_free_sql_session() OR p_chat_id IS NULL OR p_chat_id !~ '^[0-9]+$' THEN
        RETURN;
    END IF;
    v_pid := agent.fn_resolve_sender(p_chat_id::bigint) ->> 'person_id';
    IF v_pid IS NULL THEN
        RETURN;
    END IF;

    RETURN QUERY
    SELECT jm.id, jm.source, jm.board, jm.external_id, jm.title, jm.employer, jm.location, jm.url,
           jm.score, jm.is_serendipity, jm.status, jm.feedback_at, jm.created_at
      FROM career.job_matches jm
     WHERE jm.person_id = v_pid
     ORDER BY jm.feedback_at DESC NULLS LAST, jm.created_at DESC
     LIMIT LEAST(GREATEST(COALESCE(p_limit, 20), 1), 100);
END;
$$;

REVOKE ALL ON FUNCTION career.fn_read_job_matches(text, int) FROM public;
-- EXECUTE an career_rw: core.fn_provision_package_roles (GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA career).
