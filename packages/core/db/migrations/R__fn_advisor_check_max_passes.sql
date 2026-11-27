-- ============================================================
-- core.fn_advisor_check_max_passes() — Obergrenze der Lese-Durchgaenge der Schlusspruefung (READ)
--   Die eine Lese-Adresse fuer core.config advisor.check_max_passes (fehlend oder unlesbar -> 2).
--   Aufrufer: core.fn_advisor_progress (Phase check/publish), agent.fn_advisor_publish_plan (final_check_open),
--   agent.fn_advisor_record_check_findings (naechster Durchgang, Auftrag fuer den zweiten Durchgang).
--   Rueckgabe int. STABLE, INVOKER, search_path gepinnt; plpgsql (late-bound: core.fn_config_get folgt alphabetisch).
--   Tests: tests/db/core/test_fn_advisor_check_max_passes.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_advisor_check_max_passes()
RETURNS int
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    RETURN COALESCE(NULLIF(substring(COALESCE(core.fn_config_get('core', 'advisor', 'check_max_passes'), '') FROM '^\s*(\d+)\s*$'), '')::int, 2);
END;
$$;
