-- ============================================================
-- Guide-Agent — Lern-Loop-Zustand (Phase C, WS-1; Init-only, KEIN V)
-- Zweck:   Zwei additive Tabellen fuer den opt-in Tages-Lern-Loop (learn_context):
--          * agent.guide_learn_candidates — VORGESCHLAGENE Lern-Eintraege. Der Cron schlaegt nur
--            vor (schreibt AUSSCHLIESSLICH hier); der EINZIGE agent.core_contexts-Schreibpfad ist die
--            owner-gegatete Approve-fn (Per-Eintrag-HITL). target_kind 'fact' (strukturierter
--            metadata.facts-Merge) | 'note' (Prosa-Notiz unter "## Gelernt"). Queue:
--            pending -> approved | rejected | expired.
--          * agent.guide_learn_watermark — per-Quelltabelle Cursor: n8n besitzt die
--            agent.<agent>_chat_memory-Tabellen mit je eigener id-Sequenz -> ein Cursor je agent_name.
--          Beide sind EPHEMERER Loop-State -> bewusst NICHT im Backup-Block (manifest .backup).
-- Schreibpfade: Cron (Haupt-Owner-Credential) -> guide_learn_* via agent.fn_record_learn_candidates
--          (atomar, Watermark-Vorschub in derselben Tx); Orchestrator-Callback -> Status-Transition
--          via agent.fn_approve_learn_candidate / agent.fn_reject_learn_candidate.
-- Usage:   db_apply.ps1 -File packages\core\db\agent.guide_learn_init.sql
-- Tests:   tests/db/core/test_guide_learn_schema.sql (+ test_fn_record/approve/reject_learn_candidate)
-- ============================================================

CREATE SCHEMA IF NOT EXISTS agent;

-- Helper idempotent mit-definiert (Muster agent.guide_init.sql / agent.monitor_init.sql), damit
-- agent.guide_learn_init standalone anwendbar bleibt — unabhaengig von der Init-Reihenfolge.
CREATE OR REPLACE FUNCTION agent.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

-- Vorgeschlagene Lern-Eintraege (Queue mit 4 Status; Cap/Dedup/Cleanup ueber Indizes unten).
CREATE TABLE IF NOT EXISTS agent.guide_learn_candidates (
    id             serial PRIMARY KEY,
    agent_name     text   NOT NULL,                      -- Quell-Chat (finance|finance_advisor|guide) = welche *_chat_memory
    source_id      bigint NOT NULL,                      -- id der ausloesenden agent.<agent>_chat_memory-Zeile (Idempotenz)
    target_kind    text   NOT NULL CHECK (target_kind IN ('fact', 'note')),
    context_name   text   NOT NULL,                      -- Ziel-Kontext (fact: family | Fakten-Kontext eines aktiven Pakets, core.fn_facts_context_allowed; note: financial_planning|family|...)
    person_slug    text,                                 -- nur fact: person_id im family-Kontext
    field          text,                                 -- nur fact: Feldname (birth_date, steuerklasse, ...)
    proposed_value text   NOT NULL,                      -- Roh-Wert (fact) ODER Notiztext (note)
    kind           text   NOT NULL CHECK (kind IN ('new', 'update')),
    slot_key       text   NOT NULL,                      -- Dedup-Identitaet (fact: context|person|field; note: context|hash)
    rationale      text,                                 -- knappe Begruendung (woraus gelernt) — Audit + Karte
    status         text   NOT NULL DEFAULT 'pending'
                          CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
    created_at     timestamptz NOT NULL DEFAULT now(),
    proposed_at    timestamptz NOT NULL DEFAULT now(),   -- wann dem Owner als Karte vorgelegt
    expires_at     timestamptz NOT NULL,                 -- now()+learn_context.expiry_days (fn-gesetzt, config-getrieben)
    approved_at    timestamptz,
    rejected_at    timestamptz,
    updated_at     timestamptz NOT NULL DEFAULT now(),
    package        text   NOT NULL DEFAULT 'core',
    -- fact braucht person_slug + field (Slot-Identitaet); note traegt beide NULL.
    CONSTRAINT guide_learn_candidates_fact_shape
        CHECK (target_kind <> 'fact' OR (person_slug IS NOT NULL AND field IS NOT NULL)),
    -- Idempotenz: derselbe Quell-Satz erzeugt denselben Slot nie doppelt (ON CONFLICT DO NOTHING-Ziel).
    CONSTRAINT guide_learn_candidates_idem_key UNIQUE (agent_name, source_id, slot_key)
);

-- Nur EIN offener (pending) Vorschlag je (Kontext, Slot) — verhindert Karten-Spam fuer denselben Fakt;
-- abgelehnte/abgelaufene Eintraege bleiben als Rejection-/Audit-Memory liegen (Teilindex greift nur bei pending).
CREATE UNIQUE INDEX IF NOT EXISTS guide_learn_candidates_pending_slot_uq
    ON agent.guide_learn_candidates (context_name, slot_key)
    WHERE status = 'pending';

-- Cleanup-Scan (pending -> expired bei expires_at) + Dedup-/Cap-Scans.
CREATE INDEX IF NOT EXISTS guide_learn_candidates_expires_idx
    ON agent.guide_learn_candidates (expires_at);
CREATE INDEX IF NOT EXISTS guide_learn_candidates_status_slot_idx
    ON agent.guide_learn_candidates (status, slot_key);

DROP TRIGGER IF EXISTS trg_guide_learn_candidates_touch ON agent.guide_learn_candidates;
CREATE TRIGGER trg_guide_learn_candidates_touch BEFORE UPDATE ON agent.guide_learn_candidates
    FOR EACH ROW EXECUTE FUNCTION agent.touch_updated_at();

-- Per-Quelltabelle Cursor: at-most-once-lossy Vorschub in derselben fn_record-Tx (Transactional-Outbox-Muster).
CREATE TABLE IF NOT EXISTS agent.guide_learn_watermark (
    agent_name   text PRIMARY KEY,                       -- = agent.<agent>_chat_memory (eigene id-Sequenz je Tabelle)
    last_seen_id bigint NOT NULL DEFAULT 0,
    updated_at   timestamptz NOT NULL DEFAULT now()
);

DROP TRIGGER IF EXISTS trg_guide_learn_watermark_touch ON agent.guide_learn_watermark;
CREATE TRIGGER trg_guide_learn_watermark_touch BEFORE UPDATE ON agent.guide_learn_watermark
    FOR EACH ROW EXECUTE FUNCTION agent.touch_updated_at();

-- FMEA-Backstop-GRANT (Muster agent.guide_init.sql): der Guide ist ein CORE-Agent -> Lesepfade laufen
-- unter core_ro. No-op falls core_ro (noch) fehlt (Init-Phase < util_create_core_ro).
DO $$ BEGIN
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'core_ro') THEN
        GRANT SELECT ON agent.guide_learn_candidates, agent.guide_learn_watermark TO core_ro;
    END IF;
END $$;
