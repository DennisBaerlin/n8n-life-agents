-- ============================================================
-- Paperless-Paket — Schema "paperless" (Baseline-Init, idempotent)
--   Seit v0.3.0 ein schlanker LESE-Zugang auf eine bestehende Paperless-NGX-Instanz (URL + API-Token,
--   Plan ~/.claude/plans/quiet-watching-meadow.md). Das Paket haelt KEINE eigenen Daten mehr: die frueheren
--   Pipeline-Tabellen (Status-Maschine, pgvector-Chunk-Store, Backfill-Cursor) baut paperless:V001 auf
--   Bestands-Installationen zurueck.
--   Das Schema bleibt trotzdem (Paket-Vertrag, docs/package-contract.md §4): die Paket-Rollen paperless_rw/_ro
--   haengen daran (paperless_ro liest die URL-Config via core.fn_config_get), dazu der Test-Cleanup-Hook
--   paperless.fn_clear_e2e_data (R__fn_clear_e2e_data.sql).
--   Usage: psql -U <user> -d <database> -f paperless.tables_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS paperless;
