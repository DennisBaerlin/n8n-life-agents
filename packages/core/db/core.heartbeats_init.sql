-- ============================================================
-- core.heartbeats + core.heartbeat_observer — Lebenszeichen des Hintergrund-Teils und ihr Waechter
--   Anwenden via: db_apply.ps1 -File packages\core\db\core.heartbeats_init.sql
--
-- Zweck: der root-Teil (Update-Pruefung, Auftraege aus dem Chat, Sicherung) laeuft ausserhalb von n8n und kann still
--   stehen bleiben (master-Schleife im Docker-Verbund, systemd-Timer klassisch). Jeder Lauf schreibt sein Lebenszeichen
--   ueber core.fn_heartbeat_record (root per pg_su_psql, provisioning/lib/common.sh heartbeat_record); der n8n-Zeitgeber
--   core.cron_heartbeat_watch zaehlt je Lauf die beobachtete Zeit (core.fn_heartbeat_claim) und meldet dem Owner,
--   wenn ein Signal zu lange schweigt. Eine Uhr: now() der DB; einzige Ausnahme ist notified_at (Zeitpunkt der letzten
--   eigenen Sicherungs-Meldung, vom root-Teil mitgegeben).
--   Bei uns anders als ein externer Heartbeat-Dienst (Healthchecks/Uptime Kuma): kein fremder Dienst (Owner-Entscheid);
--   was der Waechter nicht sehen kann (n8n oder PostgreSQL steht, Rechner aus), meldet der Rueckblick nach der Luecke.
--
-- Ephemer (Betriebs-Zustand, keine Nutzerdaten) -> nicht im backup-Block des Manifests; nach Wiederherstellen oder
--   Neuinstallation beginnt alles mit dem ersten Beat neu.
-- Tests: tests/db/core/test_fn_heartbeat_record.sql, test_fn_heartbeat_claim.sql, test_fn_heartbeat_finish.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.heartbeats (
    signal           text PRIMARY KEY CHECK (signal IN ('loop', 'check', 'backup')),
    status           text NOT NULL,                 -- 'pending' = Zeile vom ersten Beat eines anderen Signals angelegt
    beat_at          timestamptz NOT NULL,
    status_since     timestamptz NOT NULL,
    busy_until       timestamptz,                   -- langer Schritt laeuft (Update, master-Wechsel, Sicherung im Tick)
    notified_at      timestamptz,                   -- letzte eigene Sicherungs-Meldung des root-Teils (LAST_NOTIFY)
    -- Ausnahme (c): Zustand des Waechters, nicht aus anderen Spalten ableitbar (zaehlt nur beobachtete Laufzeit)
    stale_observed_s int NOT NULL DEFAULT 0 CHECK (stale_observed_s >= 0),
    -- Ausnahme (c): laufender Vorfall und Melde-Stand (Teil der Merker-Schluessel in core.notification_state)
    incident_at      timestamptz,
    alert_stage      int NOT NULL DEFAULT 0 CHECK (alert_stage >= 0),
    last_alert_at    timestamptz,
    last_clear_at    timestamptz,
    CONSTRAINT heartbeats_status_per_signal CHECK (
           (signal = 'loop'   AND status IN ('pending', 'ok', 'busy'))
        OR (signal = 'check'  AND status IN ('pending', 'ok', 'not_release', 'skipped'))
        OR (signal = 'backup' AND status IN ('pending', 'current', 'attempted', 'nofolder'))),
    CONSTRAINT heartbeats_status_since CHECK (status_since <= beat_at),
    CONSTRAINT heartbeats_busy CHECK ((status = 'busy') = (busy_until IS NOT NULL)),
    CONSTRAINT heartbeats_busy_range CHECK (busy_until IS NULL
                                            OR (busy_until > beat_at AND busy_until <= beat_at + interval '4 hours')),
    CONSTRAINT heartbeats_notified_backup CHECK (notified_at IS NULL OR signal = 'backup'),
    CONSTRAINT heartbeats_alert CHECK ((alert_stage = 0) = (last_alert_at IS NULL)),
    CONSTRAINT heartbeats_alert_incident CHECK (alert_stage = 0 OR incident_at IS NOT NULL)
);

CREATE TABLE IF NOT EXISTS core.heartbeat_observer (
    id             boolean PRIMARY KEY DEFAULT TRUE CHECK (id),
    seen_at        timestamptz,                     -- letzter Waechter-Lauf (NULL = noch nie)
    runtime        text NOT NULL CHECK (runtime IN ('compose', 'systemd')),
    help_url       text CHECK (help_url ~ '^https://\S+$'),
    -- Ausnahme (c): offene eigene Luecke des Waechters, bis der Rueckblick gesendet ist
    lookback_from  timestamptz,
    lookback_gap_s int CHECK (lookback_gap_s > 0),
    -- Sende-Abstand nach gescheitertem Telegram-Versuch (ein Kanal -> ein Abstand fuer alle Texte)
    retry_after    timestamptz,
    fail_count     int NOT NULL DEFAULT 0 CHECK (fail_count >= 0),
    CONSTRAINT heartbeat_observer_lookback CHECK ((lookback_from IS NULL) = (lookback_gap_s IS NULL))
);
-- Rechte: root schreibt als Superuser, n8n ueber die Laufzeit-Grants auf core (apply_schema.sh Phase 4); core_ro liest
-- die Tabellen nicht (nicht auf der Erlaubnisliste in util_create_core_ro.sql).
