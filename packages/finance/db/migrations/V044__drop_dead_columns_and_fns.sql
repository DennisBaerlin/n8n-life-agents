-- ============================================================
-- V044 (finance) — Spalte und Funktionen ohne Leser entfernen
--   finance.pension_statements.is_nominal: kein Leser, kein Schreiber ausser einem Test; ob ein Wert nominal ist, sagt der
--     basis-Text von finance.fn_pension_outlook. Aeltere Sicherungen tragen die Spalte noch: Manifest backup.removed_columns.
--   finance.fn_interest_accrued_preview, finance.fn_verify_holding_shares: ausser ihren Tests kein Aufrufer.
--   Re-run-sicher (IF EXISTS). Test: tests/db/cross/test_dead_schema_values.sql
-- ============================================================
ALTER TABLE finance.pension_statements DROP COLUMN IF EXISTS is_nominal;
DROP FUNCTION IF EXISTS finance.fn_interest_accrued_preview(integer, date);
DROP FUNCTION IF EXISTS finance.fn_verify_holding_shares(integer, numeric);
