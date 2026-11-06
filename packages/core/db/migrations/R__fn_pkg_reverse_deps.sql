-- ============================================================
-- fn_pkg_reverse_deps (READ-ONLY — Reverse-Dependency-Guard fuer den Uninstall, WS-2)
--   Gegenstueck zu fn_pkg_check_deps: VOR der Deinstallation eines Pakets prueft die CLI,
--   ob ein anderes AKTIVES Paket es in seinem `requires` fuehrt (apt/dpkg-rdepends-Muster) —
--   sonst risse die Deinstallation dessen Abhaengigkeit weg. Nur `status='active'` zaehlt:
--   inaktive/entfernte Abhaengige blockieren nicht (sie laufen ohnehin nicht).
--   Eingabe jsonb: package (Pflicht).
--   RUECKGABE: {ok:true, package, dependents:[…]} — dependents ist IMMER ein jsonb-Array
--     (leer statt null, damit die CLI .[]-iterieren kann). Leerer package -> {ok:false, reason}.
--   READ-ONLY: kein Write, kein RAISE (Vorpruefung).
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_reverse_deps(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = pg_catalog   -- Hygiene-Parität zu fn_pkg_purge_data/fn_pkg_check_deps (CVE-2018-1058); Objekte schema-qualifiziert
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
