-- ============================================================
-- fn_reset_onboarding_state (Owner-Ops — Onboarding-Fortschritt auf Anfang)
--   Setzt JEDE Onboarding-Sektion auf 'unknown': Core (agent.guide_onboarding_state) UND jedes
--   Paket ueber die Konvention <pkg>.onboarding_state (docs/package-contract.md §3.2 — gleiche Spalten
--   status/status_changed_at bei allen Paketen; per-Person-Tabellen werden fuer alle Personen-Zeilen zurueckgesetzt).
--   Phase B: generischer Loop statt finance/career-Literal (estate fehlte vorher). Paket-Menge =
--   core.package_registry ∪ core.schema_version (auch --keep-data-Deinstallierte), Tabelle per to_regclass.
--   Aufrufer: core.fn_reset_user_data (Werkszustand) + packages/core/db/util/util_reset_onboarding_state.sql.
--   Schliesst das Advisor-Pflicht-Gate wieder (feature.onboarding_gate vorausgesetzt).
--   RUECKGABE: {ok:true, core:<n>, packages:{<pkg>:<n>}}
--   Tests: tests/db/core/test_fn_reset_user_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_reset_onboarding_state()
RETURNS jsonb LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkg  text;
    v_rel  text;
    v_n    int;
    v_core int;
    v_pkgs jsonb := '{}'::jsonb;
BEGIN
    UPDATE agent.guide_onboarding_state SET status = 'unknown', status_changed_at = now();
    GET DIAGNOSTICS v_core = ROW_COUNT;

    FOR v_pkg IN SELECT core.fn_package_schemas()
    LOOP
        v_rel := to_regclass(format('%I.onboarding_state', v_pkg))::text;
        CONTINUE WHEN v_rel IS NULL;
        EXECUTE format('UPDATE %s SET status = %L, status_changed_at = now()', v_rel, 'unknown');
        GET DIAGNOSTICS v_n = ROW_COUNT;
        v_pkgs := v_pkgs || jsonb_build_object(v_pkg, v_n);
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'core', v_core, 'packages', v_pkgs);
END;
$$;

REVOKE ALL ON FUNCTION core.fn_reset_onboarding_state() FROM public;
