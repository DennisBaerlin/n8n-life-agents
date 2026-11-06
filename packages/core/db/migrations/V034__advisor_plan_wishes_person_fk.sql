-- ============================================================
-- V034 — Personen-FK fuer agent.advisor_plan_wishes (Plan teilen, 2026-10-28)
--   agent.advisor_init.sql laeuft alphabetisch vor agent.persons_init.sql -> der FK auf das Read-Model agent.persons
--   kann nicht ins Init (Muster core:V014 fuer advisor_plans.person_id). ON DELETE CASCADE: ein Wunsch gehoert der
--   Person (Children-Konvention) — eine entfernte Person nimmt ihre Wuensche mit, statt das Entfernen zu blockieren.
--   Idempotent geguardet (frisches Bootstrap + Bestand).
-- ============================================================
DO $$ BEGIN
    IF to_regclass('agent.advisor_plan_wishes') IS NOT NULL AND to_regclass('agent.persons') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'advisor_plan_wishes_person_fk') THEN
        ALTER TABLE agent.advisor_plan_wishes
            ADD CONSTRAINT advisor_plan_wishes_person_fk
            FOREIGN KEY (person_id) REFERENCES agent.persons(person_id) ON DELETE CASCADE;
    END IF;
END $$;
