-- ============================================================
-- career:V006 — Job-Vorschlaege je Person (Roter Faden Paket B, Owner-Entscheid 2026-10-23)
--   score_jobs wird ein PERSON-Reminder (Manifest cron_labels.person, default_enabled=false): jede Person schaltet ihre
--   eigenen Job-Karten per rem:on|off:score_jobs (agent.reminder_prefs); cron_enable.score_jobs ist nur noch der
--   Konsolen-Notschalter fuer alle (neuer Default 'true').
--   Bestand: bisher war cron_enable.score_jobs der EINE Haushalts-Schalter. Damit niemand seine Karten verliert bzw.
--   ungefragt neue bekommt, uebernimmt jede Person den bisherigen Wert als eigene Einstellung; danach steht der
--   Notschalter auf 'true' (der Config-Seeder ueberschreibt cron_enable-Werte nie — darum hier).
--   Frische Installation: die Config-Zeile existiert zum Zeitpunkt der Migration noch nicht -> No-op (der Seed legt
--   'true' an, ohne Praeferenz-Zeilen gilt default_enabled=false = Opt-in je Person).
--   Laeuft nach dem Core-Schema (apply_schema ist paket-major): agent.reminder_prefs + agent.persons existieren.
-- ============================================================
DO $$
DECLARE
    v_old text;
BEGIN
    SELECT value INTO v_old FROM core.config WHERE category = 'cron_enable' AND key = 'score_jobs';
    IF v_old IS NULL THEN
        RETURN;   -- frische Installation: nichts zu uebernehmen
    END IF;
    -- Bestand OHNE Core-Praeferenz-Tabelle = falsche Apply-Reihenfolge: laut abbrechen (sonst verbuchte Flyway die
    -- Migration als erledigt, ohne den Notschalter umzustellen -> niemand bekaeme mehr Job-Karten).
    IF to_regclass('agent.reminder_prefs') IS NULL THEN
        RAISE EXCEPTION 'career:V006 braucht agent.reminder_prefs (Core zuerst anwenden)';
    END IF;
    INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled)
    SELECT ap.person_id, 'score_jobs', v_old = 'true'
      FROM agent.persons ap
    ON CONFLICT (person_id, cron_key) DO NOTHING;
    UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'score_jobs';
END $$;
