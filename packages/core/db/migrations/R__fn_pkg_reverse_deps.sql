-- ============================================================
-- fn_pkg_reverse_deps (READ-ONLY — Reverse-Dependency-Guard fuer den Uninstall)
--   Gegenstueck zu fn_pkg_check_deps: vor der Deinstallation eines Pakets prueft die CLI,
--   ob ein anderes aktives Paket es in seinem `requires` fuehrt, sonst risse die Deinstallation
--   dessen Abhaengigkeit weg. Nur `status='active'` zaehlt: inaktive/entfernte Abhaengige
--   blockieren nicht (sie laufen ohnehin nicht).
--   Eingabe jsonb: package (Pflicht).
--   Rueckgabe: {ok:true, package, dependents:[…]} — dependents ist immer ein jsonb-Array
--     (leer statt null, damit die CLI .[]-iterieren kann). Leerer package -> {ok:false, reason}.
--   Read-only, kein RAISE (Vorpruefung).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_reverse_deps(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog   -- Paritaet zu fn_pkg_purge_data/fn_pkg_check_deps; Objekte schema-qualifiziert
AS $$
DECLARE
    v_pkg  TEXT := trim(COALESCE(p->>'package', ''));
    v_deps TEXT[];
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;

    -- aktive Pakete, die <pkg> in requires fuehren (element-weiser Array-Match).
    SELECT COALESCE(array_agg(package ORDER BY package), '{}')
      INTO v_deps
      FROM core.package_registry
     WHERE status = 'active' AND v_pkg = ANY(requires);

    RETURN jsonb_build_object('ok', true, 'package', v_pkg, 'dependents', to_jsonb(v_deps));
END;
$$;
