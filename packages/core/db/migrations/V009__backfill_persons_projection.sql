-- ============================================================
-- V009 (core) — einmalige Projektion bestehender family-Personen nach agent.persons.
--
--   WARUM eine V-Migration: der Sync-Trigger trg_project_persons (agent.persons_init.sql)
--   zieht nur KÜNFTIGE family-Writes nach. Eine Bestands-DB, die bereits eine `family`-Zeile
--   trägt (Substrat/Prod vor dieser Phase), braucht eine EINMALIGE Projektion der schon
--   vorhandenen Personen — genau der „einmalige Daten-Backfill", für den V__-Migrationen da
--   sind (db/CLAUDE.md *Migrations-Modell*).
--
--   SICHER + IDEMPOTENT: agent.fn_project_persons upsertet je Person (ON CONFLICT DO UPDATE)
--   und reconciled (DELETE entfernter Slugs); ein erneuter Lauf wäre no-op. Fresh DB OHNE
--   family-Zeile = no-op (das spätere Onboarding-Write feuert den Trigger).
--
--   APPLY-ORDER: Inits (agent.persons_init legt Tabelle+fn an) -> V (hier, projiziert) -> R.
-- ============================================================

DO $$
DECLARE
    v_facts jsonb;
BEGIN
    SELECT metadata->'facts' INTO v_facts FROM agent.core_contexts WHERE name = 'family';
    IF v_facts IS NOT NULL THEN
        PERFORM agent.fn_project_persons(v_facts);
    END IF;
END $$;
