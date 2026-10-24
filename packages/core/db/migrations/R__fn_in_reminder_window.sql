-- ============================================================
-- core.fn_in_reminder_window(p_at) — liegt der Zeitpunkt im Erinnerungs-Fenster? (Roter Faden, Owner-Entscheid 2026-10-23)
--   Nicht zeitkritische Erinnerungen kommen nur zwischen general.reminders_from und general.reminders_until (volle
--   Stunden, Haushalts-Zeitzone der DB-Sitzung wie core.fn_today; Fenster [from, until)). Defaults 10 und 20.
--   Die Reminder-Crons sind ohnehin im Fenster terminiert (cron_toggle_lint prueft die Defaults); diese fn ist die
--   EINE Adresse fuer Laufzeit-Entscheidungen, die stuendlich laufen (Waechter-Vorwarnungen/-Problemberichte in
--   agent.fn_monitor_evaluate / fn_monitor_due). Defensiv: kaputte Werte -> Defaults, nie RAISE.
--   STABLE, INVOKER (liest ueber das DEFINER-Fenster core.fn_config_get), search_path gepinnt.
--   Tests: tests/db/core/test_fn_in_reminder_window.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_in_reminder_window(p_at timestamptz DEFAULT pg_catalog.now())
RETURNS boolean
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_from  int;
    v_until int;
    v_hour  int := extract(hour FROM (p_at AT TIME ZONE current_setting('TimeZone')))::int;
BEGIN
    BEGIN
        v_from  := COALESCE(NULLIF(core.fn_config_get('core', 'general', 'reminders_from'), '')::int, 10);
        v_until := COALESCE(NULLIF(core.fn_config_get('core', 'general', 'reminders_until'), '')::int, 20);
    EXCEPTION WHEN OTHERS THEN
        v_from := 10; v_until := 20;
    END;
    IF v_from < 0 OR v_from > 23 OR v_until < 1 OR v_until > 24 OR v_from >= v_until THEN
        v_from := 10; v_until := 20;
    END IF;
    RETURN v_hour >= v_from AND v_hour < v_until;
END;
$$;
