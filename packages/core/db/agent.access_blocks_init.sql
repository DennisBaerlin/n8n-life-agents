-- ============================================================
-- Access-Blocks — Owner-Sperrliste fuer unbekannte Anklopfer
-- Zweck:   welche numerische Telegram-Identitaet (telegram_user_id) der Owner gesperrt hat. Eine gesperrte
--          uid bekommt (a) keine Owner-Knock-Notiz mehr (fn_register_knock) und (b) kann sich auch mit einem
--          gueltigen /start <code> nicht verbinden (fn_claim_/fn_consume_pairing_challenge).
--
-- Warum eine eigene Tabelle statt einer Spalte auf agent.knock_log:
--   knock_log ist das Event-/State-Log der Anklopf-Versuche (first_seen/last_notified/knock_count);
--   eine Sperre ist eine dauerhafte Policy-Entscheidung mit anderem Lebenszyklus. Der CLI-Pfad
--   `lifeagents household block <uid>` darf eine nie-geklopfte uid sperren; eine Spalte auf knock_log
--   muesste dafuer eine synthetische Knock-Zeile fabrizieren (gefaelschtes first_seen_at/knock_count=0).
--   Block beruehrt knock_log nie.
--
-- DB-Gesetze: PK telegram_user_id (genau eine Sperr-Zeile je Identitaet; idempotentes block via
--   ON CONFLICT DO NOTHING). blocked_at = Stempel der Sperre. reason = optionaler Owner-Vermerk.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.access_blocks_init.sql
-- Tests:   tests/db/core/test_fn_is_blocked.sql (+ pairing/knock-Erweiterungen)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.access_blocks (
    telegram_user_id bigint PRIMARY KEY,            -- numerische Identitaet (nie Username)
    blocked_at       timestamptz NOT NULL DEFAULT now(),
    reason           text                            -- optionaler Owner-Vermerk
);

-- Lesepfad: das CLI-`blocked`-Listing laeuft als Superuser, fn_is_blocked unter der Haupt-Credential; kein Grant an core_ro
-- (Erlaubnisliste in util_create_core_ro.sql).
