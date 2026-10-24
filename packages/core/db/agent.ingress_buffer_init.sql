-- ============================================================
-- Ingress-Buffer — Telegram-Eingangs-Buendelung je Chat (2026-10-23)
-- Zweck:   Telegram liefert "Weiterleiten mit Kommentar" als ZWEI Updates (Datei + Text, ~0,4 s Abstand,
--          Reihenfolge nicht garantiert, kein verknuepfendes Feld). Jedes Update startete einen eigenen
--          Orchestrator-Lauf -> zwei Agent-Laeufe -> zwei Bestaetigungskarten (live msg 284/285). Der
--          Orchestrator-Eingang legt jede message hier ab (fn_record_ingress_message), wartet kurz und
--          beansprucht dann das Buendel (fn_claim_ingress_burst): genau EIN Lauf verarbeitet Text + frueheste
--          Datei als eine Nachricht, die anderen enden still.
--
-- WARUM eine eigene Tabelle: n8n hat kein Debounce und keine Per-Chat-Concurrency (nur global
--   N8N_CONCURRENCY_PRODUCTION_LIMIT); etabliertes Muster = Puffer-Store + kurzes Warten (aiogram/Raito-Album,
--   n8n-nodes-message-debounce, takopi forward_coalesce). Effizienz-Mechanik, fail-open: jeder DB-Fehler ->
--   die Nachricht laeuft wie frueher einzeln.
--
-- DB-Gesetze: PK update_id (Telegrams Dedupe-Schluessel -> ein Webhook-Retry laeuft nur einmal).
--   kind: text (Text ohne '/'), file (Foto/Dokument), solo (alles andere: Befehl, Sprache, Audio ... nie gebuendelt).
--   solo speichert nie Inhalt; eine unbeanspruchte text/file-Zeile behaelt ihn immer (sonst ginge ihr Inhalt
--   still verloren); beanspruchte Zeilen verlieren ihn (Privatsphaere). claimed_by = update_id des Laufs,
--   der die Zeile verarbeitet. EPHEMER: nicht im Backup (core sichert nur full/filtered_tables). Zeilen
--   > 2 min raeumen record und claim beim naechsten Eingang weg (kein Cron); Inhalt traegt bis dahin nur
--   eine Zeile, deren Lauf vor dem Zugriff starb (n8n-Neustart) — jede normal verarbeitete ist schon leer.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.ingress_buffer_init.sql
-- Tests:   tests/db/core/test_fn_ingress_buffer.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.ingress_buffer (
    update_id     bigint      PRIMARY KEY,              -- Telegram update_id (Dedupe)
    chat_id       bigint      NOT NULL,                 -- message.chat.id
    from_id       bigint      NOT NULL,                 -- message.from.id (Gruppen: nie zwei Personen verschmelzen)
    message_id    bigint      NOT NULL,                 -- Reihenfolge im Chat
    kind          text        NOT NULL,
    exec_id       text        NOT NULL,                 -- n8n-Execution, die die Zeile angelegt hat
    payload       jsonb,                                -- rohes Update (nur text/file, bis zur Beanspruchung)
    registered_at timestamptz NOT NULL DEFAULT clock_timestamp(),
    claimed_by    bigint,                               -- update_id des verarbeitenden Laufs
    CONSTRAINT ingress_buffer_kind_valid CHECK (kind IN ('text', 'file', 'solo')),
    CONSTRAINT ingress_buffer_solo_no_payload CHECK (kind <> 'solo' OR payload IS NULL),
    CONSTRAINT ingress_buffer_unclaimed_keeps_payload CHECK (kind = 'solo' OR claimed_by IS NOT NULL OR payload IS NOT NULL)
);

CREATE INDEX IF NOT EXISTS ingress_buffer_sender_idx ON agent.ingress_buffer (chat_id, from_id, registered_at);
CREATE INDEX IF NOT EXISTS ingress_buffer_registered_idx ON agent.ingress_buffer (registered_at);
