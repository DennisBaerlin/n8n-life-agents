-- V003__drop_fn_import_resolve_acct.sql
-- Versionierte Einmal-Migration (Flyway-V__): raeumt die verwaiste Alt-Function auf, die der
-- 5f-Rename hinterlaesst. fn_import_resolve_acct(text, jsonb) wurde in fn_import_resolve_account
-- umbenannt (Enforcement Phase 5f: ausgeschriebenes 'account' statt 'acct', konsistent mit allen
-- anderen fns). Die Definition liegt als CREATE OR REPLACE in db/migrations/R__fn_import_bundle.sql
-- -> der Repeatable legt die NEUE Function an, die ALTE bliebe sonst verwaist in der DB stehen
-- (CREATE OR REPLACE ersetzt nur gleichnamige Functions). Darum hier der explizite DROP.
--
-- KEINE BEGIN/COMMIT (der Treiber wrapt jede Migration in EINE Transaktion). IF EXISTS ->
-- idempotenz-aequivalent: fresh DB hatte die Alt-Function nie -> No-op; bestehende DB -> DROP.
-- Nur die interne Helper-Function wird gedroppt (kein Tool, kein $fromAI, nicht LLM-facing);
-- die einzigen Aufrufer stehen in derselben R__-Datei und zeigen bereits auf den neuen Namen.

DROP FUNCTION IF EXISTS finance.fn_import_resolve_acct(text, jsonb);
