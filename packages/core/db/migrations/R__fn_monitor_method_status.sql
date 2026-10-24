-- ============================================================
-- fn_monitor_method_status (READ-ONLY — ist eine Beschaffungs-Methode gerade nutzbar?)
--   Die EINE Verfuegbarkeits-Regel des Trigger-Monitorings (Phase B, docs/package-contract.md §3.9), genutzt
--   von Beschaffung (fn_monitor_acquire), Parken (fn_monitor_due/fn_monitor_evaluate), Spec-Pruefung
--   (fn_monitor_validate_params) und Anlage/Aenderung (fn_create/set_monitor_trigger).
--     * Core-Builtin (web_search | sql | none)                          -> {builtin:true,  available:true}
--     * keine Registry-Zeile                                            -> {available:false, reason: unknown}
--     * Platzhalter / fns fehlen (to_regprocedure)                      -> {available:false, reason: not installed}
--     * Paket nicht aktiv (core.fn_package_active)                      -> {available:false, reason: inactive}
--     * sonst                                                           -> {builtin:false, available:true, acquire_fn, validate_fn, package}
--   Die fn-Namen kommen NUR aus der Registry (Seeder-Boundary + Regex-CHECK) — kein Caller-Input im EXECUTE.
--   RUECKGABE: jsonb wie oben; reason ist Englisch (Agent-Layer).
--   Tests: tests/db/core/test_monitor_acquisition_methods.sql
-- ============================================================
CREATE OR REPLACE FUNCTION agent.fn_monitor_method_status(p_method text)
RETURNS jsonb LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
    v_m core.monitor_acquisition_methods%ROWTYPE;
BEGIN
    IF p_method IN ('web_search', 'sql', 'none') THEN
        RETURN jsonb_build_object('method', p_method, 'builtin', true, 'available', true);
    END IF;
    SELECT * INTO v_m FROM core.monitor_acquisition_methods m WHERE m.method = p_method;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('method', p_method, 'builtin', false, 'available', false,
            'reason', format('unknown acquisition_method %s', COALESCE(p_method, 'NULL')));
    END IF;
    IF v_m.acquire_fn IS NULL OR v_m.package IS NULL
       OR to_regprocedure(v_m.acquire_fn || '(jsonb)') IS NULL
       OR to_regprocedure(v_m.validate_fn || '(jsonb)') IS NULL THEN
        RETURN jsonb_build_object('method', p_method, 'builtin', false, 'available', false,
            'reason', format('acquisition method %s is not available (its package is not installed)', p_method));
    END IF;
    IF v_m.package <> 'core' AND NOT COALESCE(core.fn_package_active(v_m.package), false) THEN
        RETURN jsonb_build_object('method', p_method, 'builtin', false, 'available', false,
            'reason', format('acquisition method %s is not available (package %s is not active)', p_method, v_m.package));
    END IF;
    RETURN jsonb_build_object('method', p_method, 'builtin', false, 'available', true,
        'acquire_fn', v_m.acquire_fn, 'validate_fn', v_m.validate_fn, 'package', v_m.package);
END;
$$;
