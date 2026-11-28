-- ============================================================
-- Notification-State -- geteilte Owner-Benachrichtigungs-Dedup-Schicht
-- Zweck:   eine zentrale "schon-gemeldet?"-Zustandstabelle, die alle Owner-Benachrichtigungs-Producer
--          teilen (Bookkeeper-Echtzeit-Folds, Knock-Anti-Spam, Advisor-Drift-Alerts). Statt dass jeder
--          Producer seine eigene Dedup-Mechanik baut, fragt jeder Producer
--          vor dem Melden ueber core.fn_should_notify(source, key, ttl), ob die Notiz neu ist.
--
-- Etabliertes Muster: Alertmanager `nflog`
--   (ein Notify-Log, viele Producer; Dedup als Datensatz je (group_key, receiver)), PagerDuty `dedup_key`
--   / OpsGenie `alias` (offen->geschlossen = Re-Arm). Die Dedup-Logik darf je Producer verschieden sein
--   (Edge-Latch / Cooldown / level-triggered Reconcile), die geteilte State-Tabelle ist die Unifikation.
--
-- DB-Gesetze:
--   - PK (source, key): genau eine Latch-Zeile je Producer-Domaene + Dedup-Schluessel.
--   - state CHECK ('ok'|'fired'): Edge-Latch. 'ok' = armed (naechste wahre Bedingung meldet);
--     'fired' = bereits gemeldet (still, bis Re-Arm).
--   - expires_at: optionaler TTL-Backstop. NULL = rein explizit re-armed (nie auto). Gesetzt = der Latch
--     gilt nach Ablauf als wieder armed (Cooldown-Semantik fuer knock + den valid_to-/squeeze-Pfad).
--
-- Zugriff (D10): Producer schreiben ueber die publizierten SECURITY-DEFINER-Fenster core.fn_should_notify /
--   core.fn_notify_commit / core.fn_notify_resolve / core.fn_notify_forget_before (enge Paket-Rollen wie finance_rw
--   haben kein direktes core-Tabellenrecht); die Advisor-Engine (breites Haupt-Credential) reconciled ueber das
--   DEFINER-Fenster core.fn_notify_reconcile. Daneben loeschen/ersetzen Zeilen: agent.fn_claim_persona_frame (alte
--   persona_greet-Latches), core.fn_backup_restore_filtered, core.fn_pkg_purge_data, core.fn_reset_user_data,
--   agent.fn_remove_household_person. Keine direkten Tabellen-Grants noetig.
--
-- Backup: manifest.json backup.filtered_tables sichert alle Zeilen ausser den Merkern dieser Installation
--   (core.fn_notify_installation_source); core.fn_backup_restore_filtered ersetzt sie beim Restore.
--
-- Usage:   db_apply.ps1 -File packages\core\db\core.notification_init.sql
-- Tests:   tests/db/core/test_fn_should_notify.sql, tests/db/core/test_fn_notify_resolve.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.notification_state (
    source        text        NOT NULL,            -- Producer-Domaene: 'finance' | 'knock' | 'advisor:finance'
    key           text        NOT NULL,            -- Dedup-Schluessel: 'reserve_breach:42' | <uid> | <metric_key>
    state         text        NOT NULL DEFAULT 'ok'
                  CHECK (state IN ('ok', 'fired')),
    last_fired_at timestamptz,                      -- wann zuletzt ein Alarm rausging (Audit)
    expires_at    timestamptz,                      -- optionaler TTL-Backstop (NULL = rein explizit re-armed)
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (source, key)
);
