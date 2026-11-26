-- ============================================================
-- core.llm_incidents + agent.llm_held_messages — Pause der KI (Anbieter sperrt oder ist gestoert)
-- Zweck:   Ein Vorfall je Pause: der Gateway sortiert Anbieter-Fehler in feste Codes (/__llm_status), der Fehlerweg der
--          Workflows meldet sie ueber core.fn_llm_incident_note. Die Zeile traegt, was die Texte und die Nachschau brauchen
--          (Art, Datum des Anbieters, Owner-Wahl, naechste Probe). Nachrichten, die in der Pause kamen, liegen in
--          agent.llm_held_messages, bis die Person sie nach der Erholung per Knopf beantworten laesst oder verwirft.
-- Muster:  PagerDuty dedup_key / Alertmanager-Gruppe: hoechstens ein offener Vorfall, Entwarnung schliesst ihn.
-- Kinds:   spend_limit (eigenes Monatslimit oder Stufen-Obergrenze), credit_empty, auth, outage (ueberlastet,
--          Serverfehler, Netz weg). rate_limited/other oeffnen keinen Vorfall (fn).
-- Privacy: llm_held_messages haelt das rohe Telegram-Update wie agent.ingress_buffer; geloescht beim Beantworten,
--          Verwerfen und spaetestens 7 Tage nach Ende des Vorfalls (core.fn_llm_probe_due). Kein Backup (fluechtig).
-- Tests:   tests/db/core/test_fn_llm_incident_note.sql, test_fn_llm_probe_due.sql, test_fn_handle_llm_cb.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS agent;

CREATE TABLE IF NOT EXISTS core.llm_incidents (
    id                bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    kind              text        NOT NULL CHECK (kind IN ('spend_limit', 'credit_empty', 'auth', 'outage')),
    resume_at         timestamptz,                         -- Zeitpunkt laut Anbieter-Text („regain access on …“), nur spend_limit
    opened_at         timestamptz NOT NULL DEFAULT now(),
    owner_notified_at timestamptz,                         -- Owner-Karte gesendet (einmal je Vorfall)
    owner_choice      text        CHECK (owner_choice IN ('raise', 'wait')),
    next_probe_at     timestamptz NOT NULL,                -- naechste Nachschau (core.fn_llm_probe_due)
    probe_step        int         NOT NULL DEFAULT 0 CHECK (probe_step >= 0),
    probe_lock_until  timestamptz,                         -- laufende Nachschau (eine zur Zeit)
    closed_at         timestamptz,
    close_reason      text        CHECK (close_reason IN ('recovered', 'superseded')),
    CONSTRAINT llm_incidents_resume_only_spend CHECK (resume_at IS NULL OR kind = 'spend_limit'),
    CONSTRAINT llm_incidents_choice_not_outage CHECK (owner_choice IS NULL OR kind <> 'outage'),
    CONSTRAINT llm_incidents_closed_pair CHECK ((closed_at IS NULL) = (close_reason IS NULL))
);
-- Hoechstens ein offener Vorfall: ist die KI gesperrt, ist sie es fuer alle Aufrufer zugleich.
CREATE UNIQUE INDEX IF NOT EXISTS llm_incidents_one_open ON core.llm_incidents ((TRUE)) WHERE closed_at IS NULL;

CREATE TABLE IF NOT EXISTS agent.llm_held_messages (
    update_id    bigint      PRIMARY KEY,                  -- Telegram update_id (Dedupe)
    incident_id  bigint      NOT NULL REFERENCES core.llm_incidents (id) ON DELETE CASCADE,
    chat_id      bigint      NOT NULL,
    from_id      bigint      NOT NULL,
    message_id   bigint      NOT NULL,
    kind         text        NOT NULL CHECK (kind IN ('text', 'file', 'voice')),
    payload      jsonb       NOT NULL,                     -- rohes Update (Form wie agent.ingress_buffer.payload)
    sent_at      timestamptz NOT NULL,                     -- message.date (Anzeige „von 21:14“)
    held_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS llm_held_messages_sender_idx ON agent.llm_held_messages (chat_id, from_id, message_id);
