-- ============================================================
-- V004 (core) — Phase 4b: die selbstgebaute In-DB-Backup-Engine ENTFERNEN.
--   Backup/Restore laeuft ab Phase 4b ueber das Standard-Werkzeug pg_dump/pg_restore in der CLI
--   (lifeagents backup export|restore); die 6 In-DB-fns erfinden pg_dump nach und entfallen. Die
--   zugehoerigen R__-Dateien sind geloescht -> CREATE OR REPLACE laeuft nicht mehr, also droppt diese
--   versioned Migration die Orphan-fns explizit (Flyway-Standard fuer fn-Entfernung, ledger-gegated).
--   core.secret + die ACL bleiben (pgcrypto-Key dient jetzt als gpg-Passphrase der CLI).
--   Fresh-DB: die fns wurden nie angelegt -> jeder DROP ist No-op.
-- ============================================================

DROP FUNCTION IF EXISTS agent.fn_export_bundle();
DROP FUNCTION IF EXISTS agent.fn_export_bundle_enc();
DROP FUNCTION IF EXISTS agent.fn_inspect_bundle_enc(text);
DROP FUNCTION IF EXISTS agent.fn_import_restore(jsonb);
DROP FUNCTION IF EXISTS agent.fn_import_restore_enc(text);
DROP FUNCTION IF EXISTS agent.fn_restore_table(text, jsonb, boolean);
