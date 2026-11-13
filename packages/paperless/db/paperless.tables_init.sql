-- ============================================================
-- Paperless-Paket — Schema "paperless" (Baseline-Init, idempotent)
--   Schlanker Lese-Zugang auf eine bestehende Paperless-NGX-Instanz (URL + API-Token). Das Paket haelt
--   keine eigenen Daten; Pipeline-Tabellen (Status-Maschine, pgvector-Chunk-Store, Backfill-Cursor)
--   aelterer Installationen baut paperless:V001 zurueck.
--   Das Schema bleibt trotzdem (Paket-Vertrag, docs/package-contract.md §4): die Paket-Rollen paperless_rw/_ro
--   haengen daran (paperless_ro liest die URL-Config via core.fn_config_get), dazu der Test-Cleanup-Hook
--   paperless.fn_clear_e2e_data (R__fn_clear_e2e_data.sql).
--   Usage: psql -U <user> -d <database> -f paperless.tables_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS paperless;
