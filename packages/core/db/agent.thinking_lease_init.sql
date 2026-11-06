-- ============================================================
-- Thinking-Lease — "Bot denkt nach"-Schalter je Chat (2026-10-23)
-- Zweck:   Telegram zeigt den Platzhalter (sendMessageDraft, leerer Text) nur kurz (Doku: 30 s; live am Client
--          2026-10-23 nur ~8 s). Eine Schleife in core.sub_show_thinking erneuert ihn alle 5 s, SOLANGE diese
--          Zeile lebt. Lebenszyklus je Lauf (Orchestrator beim KI-Weg; agent.sub_dispatch_agent bei Paket-Befehlen
--          und Paket-Onboarding-Tipps):
--            1. beim Start (privater Chat):   fn_create_thinking_lease (TTL; verdraengt andere Schalter des Chats)
--            2. Schleife je Runde:            fn_claim_thinking_draft -> show | pause | stop
--            3. VOR der Antwort:              fn_delete_thinking_lease (wait_for_draft) — und nach der Antwort per
--               chat_id noch einmal ohne Warten (zweites Netz, 'Finish card lock'); Fehlerpfad: core.sub_error_notify
--          Offene Bestaetigungskarte im Chat (agent.hitl_pending, nicht freigegeben) = pause (keine Punkte
--          ueber der Karte), nach dem Tipp wieder show.
--
-- WARUM eine eigene Tabelle: die Schleife ist eine eigene Execution (fire-and-forget) und braucht ein
--   Stopp-Signal, das der blockierte Aufrufer setzen kann; n8n hat keinen geteilten Zustand zwischen
--   Executions. Kosmetik, kein Schreibschutz: expires_at ist die Wahrheit (TTL-Lease), jeder Fehler fail-open.
--   JE CHAT EIN SCHALTER (Telegram zeigt je Chat eine Blase): so raeumt die naechste Nachricht auch den Schalter
--   eines abgebrochenen Laufs weg (ein Abbruch ruft keinen errorWorkflow).
--
-- WETTLAUF (drafting_until): claim sperrt seine Zeile und setzt bei 'show' ein 1-s-Fenster, in dem ein Draft
--   unterwegs sein kann; das Loeschen vor der Antwort und fn_create_hitl_pending (Karte) warten es ab. So landet
--   kein Draft NACH der Antwort bzw. Karte.
--
-- DB-Gesetze: PK execution_id (ein Lauf = ein Chat). CHECK expires_at > opened_at, drafting_until > opened_at.
--   EPHEMER: nicht im Backup, kein Reset-Eintrag noetig (TTL raeumt). Zugriff nur ueber die Schreib-Credential
--   (n8n), kein core_ro-Grant.
--
-- Usage:   db_apply.ps1 -File packages\core\db\agent.thinking_lease_init.sql
-- Tests:   tests/db/core/test_fn_thinking_lease.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS agent.thinking_lease (
    execution_id   text        PRIMARY KEY,           -- n8n-Execution des Orchestrator-Laufs
    chat_id        bigint      NOT NULL,              -- privater Chat, in dem die Anzeige laeuft
    opened_at      timestamptz NOT NULL DEFAULT now(),
    expires_at     timestamptz NOT NULL,
    drafting_until timestamptz,                       -- Draft evtl. unterwegs bis hier (Wettlauf-Fenster)
    CONSTRAINT thinking_lease_expiry_after_open   CHECK (expires_at > opened_at),
    CONSTRAINT thinking_lease_drafting_after_open CHECK (drafting_until IS NULL OR drafting_until > opened_at)
);
