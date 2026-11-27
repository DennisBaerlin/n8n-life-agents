-- tests/db/estate/test_task_templates_v003_migration.sql
-- estate:V003 (echte Datei, zweimal) auf einer DB, deren task_templates noch die deutschen Text-Spalten title/detail
--   tragen: beide Spalten fallen weg, die Vorlagen-Zeilen bleiben; zweiter Lauf = no-op.
BEGIN;

DO $$
BEGIN
  ALTER TABLE estate.task_templates ADD COLUMN title text, ADD COLUMN detail text;
  UPDATE estate.task_templates SET title = 'Alt-Titel', detail = 'Alt-Erklaerung';
END $$;

\ir ../../../packages/estate/db/migrations/V003__task_templates_texts_to_catalog.sql
\ir ../../../packages/estate/db/migrations/V003__task_templates_texts_to_catalog.sql

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'estate' AND table_name = 'task_templates' AND column_name IN ('title', 'detail')) THEN
    RAISE EXCEPTION 'FAIL estate:V003 [Text-Spalten noch da]'; END IF;
  IF (SELECT count(*) FROM estate.task_templates WHERE template_key = 'death_certificate') <> 1 THEN
    RAISE EXCEPTION 'FAIL estate:V003 [Vorlagen-Zeile verloren]'; END IF;
  RAISE NOTICE 'PASS estate:V003 [Text-Spalten entfernt, Vorlagen bleiben, idempotent]';
END $$;

ROLLBACK;
