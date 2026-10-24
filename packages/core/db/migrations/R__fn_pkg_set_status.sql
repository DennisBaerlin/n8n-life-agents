-- ============================================================
-- fn_pkg_set_status (ATOMIC WRITE — Lifecycle-Status eines Pakets setzen)
--   Setzt core.package_registry.status; bei ->active wird activated_at gestempelt.
--   Aufgerufen vom CLI-Lifecycle: installed (nach Migration/Deploy), active (zuletzt,
--   atomarer Konvergenz-Deploy), inactive (deactivate — KEINE Daten geloescht).
--   Eingabe jsonb: package (Pflicht), status (Pflicht; installing|installed|active|inactive).
--   RUECKGABE: {ok:true, package, status, previous}. Unbekanntes Paket oder
--     ungueltiger Zielstatus -> {ok:false, reason} OHNE Write (korrigierbar, kein RAISE).
--   Der status-Wertebereich ist zusaetzlich per CHECK (package_registry) gesetzlich.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_set_status(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pkg    TEXT := trim(COALESCE(p->>'package', ''));
    v_status TEXT := trim(COALESCE(p->>'status', ''));
    v_prev   TEXT;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;
    IF v_status NOT IN ('installing','installed','active','inactive') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid status: ' || v_status);
    END IF;

    SELECT status INTO v_prev FROM core.package_registry WHERE package = v_pkg FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package not registered: ' || v_pkg);
    END IF;

    UPDATE core.package_registry
       SET status       = v_status,
           activated_at = CASE WHEN v_status = 'active' THEN now() ELSE activated_at END
     WHERE package = v_pkg;

    RETURN jsonb_build_object('ok', true, 'package', v_pkg, 'status', v_status, 'previous', v_prev);
END;
$$;
