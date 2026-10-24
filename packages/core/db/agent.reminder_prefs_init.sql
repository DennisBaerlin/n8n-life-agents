-- ============================================================
-- agent.reminder_prefs — Erinnerungs-Einstellung JE PERSON (Roter Faden 2026-10-23)
-- Zweck:   Fuer Reminder mit scope='person' (core.cron_labels) schaltet jede Person IHRE Zustellung selbst
--          (z. B. Nachfass-Erinnerung zum Einrichten: [Nicht mehr erinnern]). Sparse Overrides ueber dem
--          Registry-Default core.cron_labels.default_enabled (etabliertes Muster: Knock/Novu-Preferences —
--          Default zentral, Nutzer-Zeile gewinnt; der globale Notschalter core.config cron_enable gewinnt ueber beide).
--          Die EINE Pruef-Adresse ist core.fn_reminder_allowed(cron_key, person_id); geschrieben nur ueber
--          core.fn_set_reminder_pref (lehnt unbekannte / Haushalts-Keys ab).
-- DB-Gesetze:
--   - PK (person_id, cron_key): genau eine Einstellung je Person und Reminder.
--   - FK person_id -> agent.persons ON DELETE CASCADE (Config-Child: entfernte Person -> Einstellung weg).
--   - BEWUSST KEIN FK auf core.cron_labels: das Backup stellt diese Tabelle per pg_dump-Datenzeilen wieder her,
--     auch wenn ein Paket (und damit seine Registry-Zeile) gerade nicht installiert ist -> ein FK liesse den
--     Restore scheitern. Die Gueltigkeit des Keys prueft die Schreib-fn; die Uninstall-Purge raeumt verwaiste Zeilen.
-- Nutzerdaten: im Backup (core-Manifest backup.full_tables), geleert von core.fn_reset_user_data.
-- Usage:   db_apply.ps1 -File packages\core\db\agent.reminder_prefs_init.sql
-- Tests:   tests/db/core/test_fn_reminder_prefs.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.reminder_prefs (
    person_id  text NOT NULL REFERENCES agent.persons (person_id) ON DELETE CASCADE,
    cron_key   text NOT NULL CHECK (cron_key ~ '^[a-z][a-z0-9_]*$'),
    enabled    boolean NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, cron_key)
);

-- Lesepfad der Core-Agenten (Guide/Monitor-Frei-SQL) wie die anderen agent-Tabellen; No-op ohne core_ro.
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        GRANT SELECT ON agent.reminder_prefs TO core_ro;
    END IF;
END $$;
