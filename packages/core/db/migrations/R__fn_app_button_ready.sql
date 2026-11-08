-- ============================================================
-- core.fn_app_button_ready — darf der Knopf „Uebersicht“ erscheinen? (Installer-Menue-Lauf)
--   Bereit, wenn der Core-Haushalt und jedes aktive Paket mit Bildschirm (core.app_screens) fertig oder uebersprungen sind
--   (core.fn_onboarding_status; ein per_user-Paket ohne chat_id zaehlt als offen, fail-closed). Ohne solches Paket: nicht bereit.
--   Einmal bereit bleibt bereit (Latch app_button/ready): eine beim Update neue Sektion startet als unknown und naehme
--   sonst allen den Knopf. Nur core.fn_reset_onboarding_state hebt den Latch auf.
--   Rueckgabe: boolean. Seiteneffekt: setzt den Latch beim ersten Bereit. Aufrufer: postgres-Superuser.
--   Tests: tests/db/core/test_fn_app_button_state.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_app_button_ready()
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog
AS $$
DECLARE
    v_pkg text;
    v_any boolean := false;
BEGIN
    IF EXISTS (SELECT 1 FROM core.notification_state n
                WHERE n.source = 'app_button' AND n.key = 'ready' AND n.state = 'fired') THEN
        RETURN true;
    END IF;
    IF (core.fn_onboarding_status('core') ->> 'complete')::boolean IS NOT TRUE THEN
        RETURN false;
    END IF;
    FOR v_pkg IN SELECT DISTINCT s.package FROM core.app_screens s WHERE core.fn_package_active(s.package) LOOP
        v_any := true;
        IF (core.fn_onboarding_status(v_pkg) ->> 'complete')::boolean IS NOT TRUE THEN
            RETURN false;
        END IF;
    END LOOP;
    IF NOT v_any THEN
        RETURN false;
    END IF;
    PERFORM core.fn_should_notify('app_button', 'ready');
    RETURN true;
END;
$$;
REVOKE ALL ON FUNCTION core.fn_app_button_ready() FROM public;
