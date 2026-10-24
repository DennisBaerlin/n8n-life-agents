-- ============================================================
-- Notification-State -- geteilte Owner-Benachrichtigungs-Dedup-Schicht (Phase Notify)
-- Zweck:   EINE zentrale "schon-gemeldet?"-Zustandstabelle, die ALLE Owner-Benachrichtigungs-Producer
--          teilen (Bookkeeper-Echtzeit-Folds, Knock-Anti-Spam, Advisor-Drift-Alerts). Statt dass jeder
--          Producer seine eigene Dedup-Mechanik baut (frueher: knock = Cooldown via agent.knock_log,
--          advisor = Edge-Latch via core.advisor_review_state, Folds = GAR keine), fragt jeder Producer
--          vor dem Melden ueber core.fn_should_notify(source, key, ttl), ob die Notiz neu ist.
--
-- ETABLIERTES MUSTER (Established-Pattern-Challenge, 2 Runden Red/Blue/Opus): Alertmanager `nflog`
--   (ein Notify-Log, viele Producer; Dedup als Datensatz je (group_key, receiver)), PagerDuty `dedup_key`
--   / OpsGenie `alias` (offen->geschlossen = Re-Arm). Die Dedup-LOGIK darf je Producer verschieden sein
--   (Edge-Latch / Cooldown / level-triggered Reconcile), die geteilte STATE-Tabelle ist die Unifikation.
--
-- DB-Gesetze:
--   - PK (source, key): genau EINE Latch-Zeile je Producer-Domaene + Dedup-Schluessel.
--   - state CHECK ('ok'|'fired'): Edge-Latch. 'ok' = armed (naechste wahre Bedingung meldet);
--     'fired' = bereits gemeldet (still, bis Re-Arm).
--   - expires_at: optionaler TTL-Backstop. NULL = rein explizit re-armed (NIE auto). Gesetzt = der Latch
--     gilt nach Ablauf als wieder armed (Cooldown-Semantik fuer knock + den valid_to-/squeeze-Pfad).
--
-- ZUGRIFF (D10): geschrieben AUSSCHLIESSLICH ueber die publizierten SECURITY-DEFINER-Fenster
--   core.fn_should_notify / core.fn_notify_resolve (enge Paket-Rollen wie finance_rw haben KEIN direktes
--   core-Tabellenrecht); die Advisor-Engine (breites Haupt-Credential) reconciled ebenfalls ueber das
--   DEFINER-Fenster core.fn_notify_reconcile. Keine direkten Tabellen-Grants noetig.
--
-- EPHEMER (kein Nutzerinhalt, regeneriert sich): NICHT im Backup (kein manifest.json-backup-Eintrag).
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
