-- ============================================================
-- HITL-Pending — Karte-offen-Sperre je Chat (Fix C, 2026-10-22)
-- Zweck:   solange eine Bestaetigungskarte des Gates agent.tool_human_approval offen ist, parkt n8n die
--          ganze Kette orchestrator -> agent -> tool -> gate; das Chat-Gedaechtnis entsteht erst am Lauf-
--          Ende. Eine Text-/Sprachnachricht in dieser Zeit startete einen zweiten Lauf ohne die Kartenrunde
--          ("vergessene" Werte). Lebenszyklus je Karte:
--            1. Gate VOR dem sendAndWait: fn_create_hitl_pending (Zeile fuer den URSPRUNGS-Chat der Anfrage)
--            2. Gate nach Tipp/Timeout:   fn_set_hitl_pending_released (released_at + kurze Gnadenfrist) —
--               die Kette dahinter laeuft noch (Agent-Antwort + Gedaechtnis), die Sperre bleibt so lange
--            3. Orchestrator nach seiner Antwort: fn_delete_hitl_pending (freigegebene Zeilen des Chats weg)
--          Der Orchestrator-Pre-Router liest fn_get_hitl_pending_state und antwortet bei offener Zeile mit
--          festem Hinweis statt einen Agenten zu starten.
--
-- WARUM eine eigene Tabelle (arch-challenge "bei uns anders"): n8n hat keinen Pro-Chat-Wartezustand
--   (die Executions-API filtert `waiting` ohne Chat-Bezug). Effizienz-Lock, kein Schreibschutz:
--   expires_at ist die Wahrheit (TTL-Lease, kein Fencing noetig), jeder Fehler ist fail-open.
--
-- DB-Gesetze: PK (chat_id, execution_id) -> mehrere offene Karten je Chat erlaubt (live lagen 3);
--   own_card = die Karte liegt im Ursprungs-Chat selbst (false = Freigabe durch jemand anderen, z. B.
--   Owner-Stufe im Vier-Augen-Pfad -> anderer Hinweistext). CHECK expires_at > opened_at.
--   EPHEMER: nicht im Backup, kein Reset-Eintrag noetig (TTL raeumt).
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.hitl_pending_init.sql
-- Tests:   tests/db/core/test_fn_hitl_pending.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.hitl_pending (
    chat_id      bigint      NOT NULL,                -- Ursprungs-Chat der Anfrage (message.chat.id)
    execution_id text        NOT NULL,                -- n8n-Execution des Gate-Laufs
    own_card     boolean     NOT NULL DEFAULT TRUE,   -- Karte im Ursprungs-Chat (false = wartet auf Freigabe anderer)
    opened_at    timestamptz NOT NULL DEFAULT now(),
    released_at  timestamptz,                         -- Tipp/Timeout am Gate; Kette laeuft noch bis zur Antwort
    expires_at   timestamptz NOT NULL,
    PRIMARY KEY (chat_id, execution_id),
    CONSTRAINT hitl_pending_expiry_after_open CHECK (expires_at > opened_at)
);
-- Endgueltig bestaetigt (Bot mit Gesicht, 2026-10-30): setzt das Gate an seinen Erfolgs-Ausgaengen fuer ALLE Zeilen
-- seiner Execution (agent.fn_set_hitl_pending_approved); NULL = (noch) nicht bestaetigt, auch nach Tipp eines
-- Mitglieds, wenn der Owner danach ablehnt. Lesepfad: agent.fn_claim_persona_sticker (Daumen-hoch-Sticker).
ALTER TABLE agent.hitl_pending ADD COLUMN IF NOT EXISTS approved boolean;

CREATE INDEX IF NOT EXISTS hitl_pending_execution_idx ON agent.hitl_pending (execution_id);

-- Lesepfad: Orchestrator-Pre-Router unter core_ro (Lese-Konsistenz, falls die Init standalone ohne die
-- util-Blanket-Grants laeuft; Muster agent.access_blocks).
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        GRANT SELECT ON agent.hitl_pending TO core_ro;
    END IF;
END $$;
