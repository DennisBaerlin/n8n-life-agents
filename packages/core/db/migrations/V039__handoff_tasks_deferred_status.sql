-- ============================================================
-- V039 (core) — Status 'deferred' fuer agent.handoff_tasks auf Bestands-DBs
--   Das Inline-CHECK des Status aus agent.advisor_init.sql heisst handoff_tasks_status_check; CREATE TABLE IF NOT EXISTS
--   aendert es auf einer Bestands-DB nicht. Diese Migration ersetzt es durch die Fassung mit 'deferred' (Nicht-Endzustand
--   "vereinbart, so noch nicht eintragbar"). Alt-Zeilen (open/working/done/cancelled) bestehen beide Fassungen; der Tausch
--   prueft sie beim ADD erneut. Frische DB (Inline-CHECK schon mit 'deferred') = no-op. Re-run-sicher.
--   Test: tests/db/core/test_handoff_tasks_v039_migration.sql
-- ============================================================
DO $$ BEGIN
    IF to_regclass('agent.handoff_tasks') IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conrelid = 'agent.handoff_tasks'::regclass AND conname = 'handoff_tasks_status_check'
           AND pg_get_constraintdef(oid) LIKE '%deferred%') THEN
        ALTER TABLE agent.handoff_tasks DROP CONSTRAINT IF EXISTS handoff_tasks_status_check;
        ALTER TABLE agent.handoff_tasks ADD CONSTRAINT handoff_tasks_status_check
            CHECK (status IN ('open', 'working', 'deferred', 'done', 'cancelled'));
    END IF;
END $$;
