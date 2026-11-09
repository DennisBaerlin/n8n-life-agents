-- ============================================================
-- core.proactive_budget / core.proactive_deferred -- Tagesbudget ungefragter Nachrichten je Empfaenger
-- Zweck:   Ein Cron, mehrere Pakete oder Empfaenger-Items belegen EINEN Slot je Tag; core.fn_proactive_claim zaehlt
--          verschiedene Slots gegen general.proactive_daily_max. proactive_deferred merkt den ersten abgewiesenen Tag
--          eines normal-Slots (Altern: nach general.proactive_age_days wird er wie priority behandelt).
-- DB-Gesetze:
--   - PK (person_id, day, slot): ein Slot zaehlt je Tag genau einmal.
--   - class CHECK: normal|priority|deadline.
--   - FK person_id -> agent.persons ON DELETE CASCADE (entfernte Person -> Zaehler weg).
-- EPHEMER: nicht im Backup, von core.fn_reset_user_data geleert. Geschrieben nur ueber core.fn_proactive_claim (DEFINER).
-- Tests:   tests/db/core/test_fn_proactive_claim.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.proactive_budget (
    person_id  text        NOT NULL REFERENCES agent.persons (person_id) ON DELETE CASCADE,
    day        date        NOT NULL,
    slot       text        NOT NULL,
    class      text        NOT NULL CHECK (class IN ('normal', 'priority', 'deadline')),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, day, slot)
);

CREATE TABLE IF NOT EXISTS core.proactive_deferred (
    person_id text NOT NULL REFERENCES agent.persons (person_id) ON DELETE CASCADE,
    slot      text NOT NULL,
    since     date NOT NULL,
    last_rejected date NOT NULL,                  -- Luecke > 1 Tag: die Meldung hatte sich erledigt, since faengt neu an
    PRIMARY KEY (person_id, slot)
);
