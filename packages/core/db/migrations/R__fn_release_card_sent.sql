-- ============================================================
-- core.fn_release_card_sent(tag) (Write — Update-Hinweis 2026-10-24)
--   Merkt "Karte fuer <tag> ist raus" — vom root-Check erst NACH einem 2xx von Telegram gerufen (sonst ginge die
--   Karte bei einem Netzfehler fuer immer verloren). Edge-Latch ueber das geteilte Notify-Fenster
--   core.fn_should_notify('release_update', <tag>, NULL): eine Karte je neuestem Tag, kein Re-Arm (eine neuere
--   Version ist ein neuer Key). Der Latch ist zugleich die Freigabe fuer upd:now:<tag> (core.fn_handle_update_cb).
--   RUECKGABE: true = jetzt gemerkt | false = war schon gemerkt oder kein stabiles Tag. Nie RAISE.
--   Tests: tests/db/core/test_fn_release_card.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_release_card_sent(p_tag text)
RETURNS boolean
LANGUAGE plpgsql
SET search_path = pg_catalog, pg_temp
AS $$
BEGIN
    IF core.fn_semver_cmp(p_tag, p_tag) IS NULL THEN
        RETURN false;
    END IF;
    RETURN core.fn_should_notify('release_update', p_tag, NULL);
END;
$$;
