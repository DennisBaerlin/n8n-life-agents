-- V004__drop_redundant_import_staging_index.sql
-- Versionierte Einmal-Migration (Flyway-V__): droppt den redundanten Index
-- finance_import_staging_batch_idx ON (batch_id, row_no). Die Tabelle traegt bereits
-- UNIQUE (batch_id, row_no) (agent.import_init.sql) -> deren UNIQUE-Index deckt dieselben
-- Spalten in derselben Reihenfolge ab; der zusaetzliche Non-Unique-Index ist ein reines
-- Duplikat (doppelter Schreib-/Wartungsaufwand, kein Query-Nutzen).
--
-- Der CREATE INDEX IF NOT EXISTS in agent.import_init.sql wurde mit dieser Migration entfernt
-- (fresh DB legt ihn nie an -> V004 ist dort No-op via IF EXISTS); bestehende DB -> DROP.
--
-- KEINE BEGIN/COMMIT (der Treiber wrapt jede Migration in EINE Transaktion). Kein CONCURRENTLY:
-- Staging-Tabelle (kurze, transiente Batches) -> der kurze ACCESS-EXCLUSIVE-Lock ist unkritisch
-- (single-user, keine Dauerlast).

DROP INDEX IF EXISTS finance.import_staging_batch_idx;
