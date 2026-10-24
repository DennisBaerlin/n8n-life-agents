-- tests/db/core/test_fn_in_reminder_window.sql
-- core.fn_in_reminder_window: Fenster [reminders_from, reminders_until) in der Haushalts-Zeitzone der Sitzung,
-- Defaults 10/20, kaputte Werte -> Defaults. BEGIN..ROLLBACK.
BEGIN;
SET LOCAL TimeZone = 'Europe/Berlin';

DO $$
BEGIN
  DELETE FROM core.config WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  IF core.fn_in_reminder_window('2026-10-23 09:59:00+02') THEN RAISE EXCEPTION 'FAIL [09:59 ausserhalb]'; END IF;
  IF NOT core.fn_in_reminder_window('2026-10-23 10:00:00+02') THEN RAISE EXCEPTION 'FAIL [10:00 innerhalb]'; END IF;
  IF NOT core.fn_in_reminder_window('2026-10-23 19:59:00+02') THEN RAISE EXCEPTION 'FAIL [19:59 innerhalb]'; END IF;
  IF core.fn_in_reminder_window('2026-10-23 20:00:00+02') THEN RAISE EXCEPTION 'FAIL [20:00 ausserhalb]'; END IF;
  -- Zeitzone: 08:30 UTC = 10:30 Berlin (Sommerzeit) -> innerhalb
  IF NOT core.fn_in_reminder_window('2026-07-01 08:30:00+00') THEN RAISE EXCEPTION 'FAIL [Haushalts-Zeitzone]'; END IF;

  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'general', 'reminders_from', '8'), ('core', 'general', 'reminders_until', '22');
  IF NOT core.fn_in_reminder_window('2026-10-23 08:00:00+02') THEN RAISE EXCEPTION 'FAIL [Owner-Wert 8 gilt]'; END IF;
  IF NOT core.fn_in_reminder_window('2026-10-23 21:30:00+02') THEN RAISE EXCEPTION 'FAIL [Owner-Wert 22 gilt]'; END IF;

  UPDATE core.config SET value = '23' WHERE category = 'general' AND key = 'reminders_from';  -- from >= until
  IF core.fn_in_reminder_window('2026-10-23 09:00:00+02') OR NOT core.fn_in_reminder_window('2026-10-23 11:00:00+02') THEN
    RAISE EXCEPTION 'FAIL [kaputtes Fenster -> Defaults 10/20]'; END IF;
  RAISE NOTICE 'PASS test_fn_in_reminder_window';
END $$;

ROLLBACK;
