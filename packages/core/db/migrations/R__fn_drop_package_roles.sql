-- ============================================================
-- fn_drop_package_roles (ATOMIC, privilegiert — per-Paket-Rollen entfernen, D10)
--   Gegenstueck zu fn_provision_package_roles fuer den purge-Pfad
--   (`package uninstall --purge`): entfernt <pkg>_rw / <pkg>_ro restlos. Idempotent
--   (Rolle fehlt schon -> removed=false, kein RAISE).
--
--   Reihenfolge (Pflicht): DROP OWNED BY <rolle> ZUERST — das widerruft alle der Rolle
--   erteilten Privilegien + entfernt ihre Default-Privilege-Eintraege in DIESER DB; sonst
--   scheitert DROP ROLE mit "role cannot be dropped because some objects depend on it".
--   Diese Rollen BESITZEN keine Objekte (die Tabellen gehoeren postgres) -> DROP OWNED
--   loescht nur Grants/ACL, keine Daten. Das Paket-Schema selbst dropt der CLI-Lifecycle
--   separat per DROP SCHEMA <pkg> CASCADE.
--
--   Privilegiert (DROP ROLE = Superuser); laeuft als der aufrufende Superuser, SECURITY
--   INVOKER (kein Eskalations-Fenster).
--
--   Eingabe jsonb: package (Pflicht).
--   RUECKGABE: {ok:true, package, dropped} (dropped = mind. eine Rolle entfernt).
--     Leerer/ungueltiger Name -> {ok:false, reason}.
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_drop_package_roles(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_pkg     TEXT := trim(COALESCE(p->>'package', ''));
    v_role    TEXT;
    v_dropped BOOLEAN := FALSE;
BEGIN
    IF v_pkg = '' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'package must be non-empty');
    END IF;
    IF v_pkg !~ '^[a-z][a-z0-9_]*$' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'invalid package name (expect ^[a-z][a-z0-9_]*$): ' || v_pkg);
    END IF;

    FOREACH v_role IN ARRAY ARRAY[v_pkg || '_rw', v_pkg || '_ro'] LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
            EXECUTE format('DROP OWNED BY %I', v_role);   -- Grants/ACL widerrufen (keine Objekte im Besitz)
            EXECUTE format('DROP ROLE %I', v_role);
            v_dropped := TRUE;
        END IF;
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'package', v_pkg, 'dropped', v_dropped);
END;
$$;
