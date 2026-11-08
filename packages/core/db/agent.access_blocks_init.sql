-- ============================================================
-- Access-Blocks — Owner-Sperrliste fuer unbekannte Anklopfer (WS-5d Owner-Lifecycle)
-- Zweck:   eine DEDIZIERTE Policy-Relation: welche numerische Telegram-Identitaet (telegram_user_id)
--          hat der Owner gesperrt. Eine gesperrte uid bekommt (a) keine Owner-Knock-Notiz mehr
--          (fn_register_knock) UND (b) kann sich auch mit einem gueltigen /start <code> nicht
--          verbinden (fn_claim_/fn_consume_pairing_challenge) — Owner-Entscheid „auch Code-Einloesen
--          blockieren" (staerkere Sperre).
--
-- WARUM eine EIGENE Tabelle (NICHT eine Spalte auf agent.knock_log) — arch-challenge D2 ADOPT-Standard:
--   knock_log ist das EVENT-/State-Log der Anklopf-Versuche (first_seen/last_notified/knock_count);
--   eine Sperre ist eine DURABLE Policy-Entscheidung mit anderem Lebenszyklus. Entscheidend: der
--   CLI-Pfad `lifeagents household block <uid>` darf eine NIE-geklopfte uid sperren — eine Spalte auf
--   knock_log muesste dafuer eine SYNTHETISCHE Knock-Zeile fabrizieren (gefaelschtes first_seen_at/
--   knock_count=0) = Integritaets-Korruption des Event-Logs. Eine getrennte Tabelle bleibt sauber
--   (Vorbild: Mastodon account_blocks, Discourse screened_*). Block beruehrt knock_log NIE.
--
-- DB-Gesetze: PK telegram_user_id (genau EINE Sperr-Zeile je Identitaet; idempotentes block via
--   ON CONFLICT DO NOTHING). blocked_at = Stempel der Sperre. reason = optionaler Owner-Vermerk.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.access_blocks_init.sql
-- Tests:   tests/db/core/test_fn_is_blocked.sql (+ pairing/knock-Erweiterungen)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.access_blocks (
    telegram_user_id bigint PRIMARY KEY,            -- numerische Identitaet (NIE Username)
    blocked_at       timestamptz NOT NULL DEFAULT now(),
    reason           text                            -- optionaler Owner-Vermerk
);

-- Lesepfad: das CLI-`blocked`-Listing laeuft als Superuser, fn_is_blocked unter der Haupt-Credential; kein Grant an core_ro
-- (Erlaubnisliste in util_create_core_ro.sql).
