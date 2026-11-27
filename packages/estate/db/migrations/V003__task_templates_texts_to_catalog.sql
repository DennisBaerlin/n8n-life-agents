-- ============================================================
-- V003 (estate) — Aufgaben-Texte der Vorlagen nur noch im Textkatalog
--   Titel/Erklaerung der task_templates stehen als estate.task.<template_key>.title|.detail in den locales; die
--   deutschen Spalten title/detail auf Bestands-DBs fallen weg (das Init nimmt NOT NULL vorher zurueck, weil Inits vor
--   den Migrationen laufen). Bereits instanziierte case_tasks behalten ihren Text-Schnappschuss; den Versand rendert
--   cron_remind_case_tasks fuer Vorlagen-Aufgaben aus dem Katalog in der Empfaenger-Sprache.
--   Frische DB (Spalten nie angelegt) = no-op. Re-run-sicher.
--   Test: tests/db/estate/test_fn_case_template_rows.sql (Spalten weg, Texte aus dem Katalog)
-- ============================================================
ALTER TABLE estate.task_templates DROP COLUMN IF EXISTS title;
ALTER TABLE estate.task_templates DROP COLUMN IF EXISTS detail;
