-- ============================================================
-- V035 — Personen-FK fuer agent.handoff_tasks (Uebergabe Berater -> Buchhalter)
--   agent.advisor_init.sql laeuft alphabetisch vor agent.persons_init.sql -> der FK auf das Read-Model agent.persons
--   kann nicht ins Init (Muster core:V034). ON DELETE CASCADE: eine vereinbarte Aufgabe gehoert der Person, die
--   zugestimmt hat (Children-Konvention) — eine entfernte Person nimmt ihre Aufgaben mit, statt das Entfernen zu
--   blockieren. Idempotent geguardet (frisches Bootstrap + Bestand).
-- ============================================================
DO $$ BEGIN
    IF to_regclass('agent.handoff_tasks') IS NOT NULL AND to_regclass('agent.persons') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'handoff_tasks_person_fk') THEN
        ALTER TABLE agent.handoff_tasks
            ADD CONSTRAINT handoff_tasks_person_fk
            FOREIGN KEY (person_id) REFERENCES agent.persons(person_id) ON DELETE CASCADE;
    END IF;
END $$;
