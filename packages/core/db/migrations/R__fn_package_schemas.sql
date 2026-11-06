-- ============================================================
-- fn_package_schemas (READ-ONLY — welche Domaenen-Pakete haben gerade ein eigenes Schema?)
--   Die EINE Paket-Menge der Lebenszyklus-fns (Phase B): fn_reset_user_data, fn_reset_onboarding_state,
--   agent.fn_clear_e2e_data. Quelle = core.package_registry UNION core.schema_version (letztere faengt mit
--   --keep-data deinstallierte Pakete, deren Daten noch liegen), ohne core, Namens-Regex (die Namen landen
--   in format('%I…')), nur wenn das Schema existiert. Bewusst NICHT nach status='active' gefiltert (anders als
--   fn_onboarding_pending_packages): ein Reset/Cleanup muss auch Daten inaktiver Pakete erfassen.
--   RUECKGABE: SETOF text, alphabetisch (deterministische Reihenfolge der Hooks/TRUNCATEs).
--   Tests: tests/db/core/test_fn_reset_user_data.sql, tests/db/core/test_core_only.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_package_schemas()
RETURNS SETOF text LANGUAGE sql STABLE
SET search_path = pg_catalog
AS $$
    SELECT s.package
      FROM (SELECT package FROM core.package_registry
            UNION SELECT package FROM core.schema_version) s
     WHERE s.package <> 'core' AND s.package ~ '^[a-z][a-z0-9_]*$'
       AND to_regnamespace(s.package) IS NOT NULL
     ORDER BY s.package;
$$;

REVOKE ALL ON FUNCTION core.fn_package_schemas() FROM public;
