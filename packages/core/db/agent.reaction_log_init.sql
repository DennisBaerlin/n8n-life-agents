-- ============================================================
-- Reaktions-Protokoll — Emoji-Reaktionen des Bots an Nutzer-Nachrichten (agent.fn_claim_reaction)
-- Zweck:   Tages-Kontingent der Gefuehls-Reaktionen je Person (kind 'mood' zaehlt) und Doppel-Sperre je Nachricht.
--          kind: seen = 👀 Lebenszeichen an Foto/Dokument; done = 👌 nach endgueltig bestaetigter Karte;
--                mood = Stimmung neben einer Antwort (zaehlt zur Obergrenze); answer = Stimmung statt Text.
-- WARUM eine eigene Tabelle statt core.fn_should_notify: die Notify-Schicht kennt nur "1 je Fenster" (eine Zeile je
--   Schluessel); die Obergrenze ist "N je Tag". Verlaufsquelle fuer spaetere Rueckbezuege.
-- DB-Gesetze: UNIQUE (chat_id, message_id, kind) -> nie zweimal dieselbe Art an dieselbe Nachricht; Koppel-CHECK
--   kind <-> emoji (Telegram-Liste, ❤ ohne VS16 wie die Allowlist im LLM-Gateway provisioning/llm_gateway/server.js).
--   Person per FK, ON DELETE CASCADE (Person entfernt -> Protokoll weg). Aufbewahrung 30 Tage: fn_claim_reaction
--   loescht aeltere Zeilen der Person im selben Aufruf. Nicht im Backup (Manifest-backup-Block, ephemer).
-- Usage:   db_apply.ps1 -File packages\core\db\agent.reaction_log_init.sql
-- Tests:   tests/db/core/test_fn_claim_reaction.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.reaction_log (
    id          bigserial   PRIMARY KEY,
    person_id   text        NOT NULL REFERENCES agent.persons (person_id) ON DELETE CASCADE,
    chat_id     bigint      NOT NULL,
    message_id  bigint      NOT NULL,
    kind        text        NOT NULL,
    emoji       text        NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT reaction_log_kind_valid  CHECK (kind IN ('seen', 'done', 'mood', 'answer')),
    CONSTRAINT reaction_log_emoji_valid CHECK (emoji IN ('👀', '👌', '❤', '🎉', '🙏', '😁')),
    CONSTRAINT reaction_log_kind_emoji  CHECK (
           (kind = 'seen' AND emoji = '👀')
        OR (kind = 'done' AND emoji = '👌')
        OR (kind IN ('mood', 'answer') AND emoji IN ('❤', '🎉', '🙏', '😁'))),
    CONSTRAINT reaction_log_once UNIQUE (chat_id, message_id, kind)
);

CREATE INDEX IF NOT EXISTS reaction_log_person_created_idx ON agent.reaction_log (person_id, created_at);
