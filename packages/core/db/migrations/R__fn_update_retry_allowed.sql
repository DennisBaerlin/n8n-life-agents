-- ============================================================
-- core.fn_update_retry_allowed(tag) (read-only — Update-Hinweis 2026-10-24)
--   Die EINE Regel fuer [Erneut versuchen] (upd:retry:<tag>): genutzt vom Callback-Handler (darf der Tap einen
--   Auftrag anlegen?) und von core.fn_update_report (wird der Knopf ueberhaupt angeboten?).
--   Erlaubt genau dann, wenn der zuletzt abgeschlossene Auftrag fuer <tag> partial/failed/interrupted ist, sein
--   Grund keine Sicherheits-/Sinnlos-Wiederholung ist (signature, checksum, downgrade, not_found) und seit dem
--   letzten [Jetzt aktualisieren] fuer <tag> weniger als 2 Wiederholungen liefen (keine Schleife; danach bleiben
--   Rueckweg und [Problem melden]).
--   RUECKGABE: boolean (nie NULL). Tests: tests/db/core/test_fn_update_requests.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_update_retry_allowed(p_tag text)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_last    core.update_requests%ROWTYPE;
    v_base_id bigint;
    v_retries int;
BEGIN
    IF core.fn_semver_cmp(p_tag, p_tag) IS NULL THEN
        RETURN false;
    END IF;
    SELECT * INTO v_last
      FROM core.update_requests
     WHERE tag = p_tag AND finished_at IS NOT NULL
     ORDER BY finished_at DESC, id DESC
     LIMIT 1;
    IF NOT FOUND
       OR v_last.outcome NOT IN ('partial', 'failed', 'interrupted')
       OR COALESCE(v_last.reason_code, '') IN ('signature', 'checksum', 'downgrade', 'not_found') THEN
        RETURN false;
    END IF;
    SELECT COALESCE(max(id), 0) INTO v_base_id
      FROM core.update_requests WHERE tag = p_tag AND kind = 'update';
    SELECT count(*) INTO v_retries
      FROM core.update_requests WHERE tag = p_tag AND kind = 'retry' AND id > v_base_id;
    RETURN v_retries < 2;
END;
$$;
