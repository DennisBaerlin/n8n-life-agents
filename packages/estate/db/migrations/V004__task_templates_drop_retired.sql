-- ============================================================
-- V004 (estate) — Spalte task_templates.retired entfernen
--   Nie true: der Seed setzte sie bei jedem Apply auf false zurueck, kein Werkzeug schreibt sie. Vorlagen bleiben weiter
--   ungeloescht (case_tasks.template_key FK RESTRICT). CASCADE nimmt estate.v_task_templates mit, die die Spalte zeigte;
--   R__v_task_templates legt die View ohne sie neu an. task_templates ist nicht im Backup (Manifest exclude_tables).
--   Frische DB (Spalte nie angelegt) = no-op. Re-run-sicher. Test: tests/db/cross/test_dead_schema_values.sql
-- ============================================================
ALTER TABLE estate.task_templates DROP COLUMN IF EXISTS retired CASCADE;
