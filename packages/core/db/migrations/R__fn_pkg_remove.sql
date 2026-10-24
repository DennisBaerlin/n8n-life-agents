-- ============================================================
-- fn_pkg_remove (ATOMIC WRITE — Registry-Eintrag eines Pakets entfernen)
--   Loescht NUR die core.package_registry-Zeile (Deregistrierung). Das eigentliche
--   Aufraeumen (DROP SCHEMA <pkg> CASCADE, DROP ROLE, paket-gelieferte core_contexts-
--   Zeilen, Config, Workflows/Credentials) macht der CLI-Lifecycle (pkg_lifecycle.sh)
--   ausserhalb — diese fn ist der DB-Schritt "aus der Registry nehmen".
--   Eingabe jsonb: package (Pflicht).
--   RUECKGABE: {ok:true, package, removed} (removed = DB-entschieden: true wenn eine
--     Zeile geloescht wurde, false wenn es das Paket nicht gab — idempotent, kein RAISE).
--     Leerer package -> {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_pkg_remove(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pkg     TEXT := trim(COALESCE(p->>'package', ''));
    v_deleted INT;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;

    DELETE FROM core.package_registry WHERE package = v_pkg;
    GET DIAGNOSTICS v_deleted = ROW_COUNT;

    RETURN jsonb_build_object('ok', true, 'package', v_pkg, 'removed', v_deleted > 0);
END;
$$;
