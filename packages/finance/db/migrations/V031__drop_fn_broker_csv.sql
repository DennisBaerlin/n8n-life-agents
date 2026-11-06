-- V031__drop_fn_broker_csv.sql
-- Versionierte Einmal-Migration (Flyway-V__): raeumt die Alt-Functions des Rename "broker_csv" -> "bank_export"
-- (Bank-Import-Modul) auf. Die neuen Functions legen die Repeatables R__fn_bank_export_*.sql an; CREATE OR REPLACE
-- ersetzt nur gleichnamige Functions, die alten blieben sonst verwaist in der DB stehen (Muster V003).
-- KEINE BEGIN/COMMIT (der Treiber wrapt). IF EXISTS -> frische DB: No-op.

DROP FUNCTION IF EXISTS finance.fn_broker_csv_normalize(jsonb);
DROP FUNCTION IF EXISTS finance.fn_broker_csv_account_profile(int);
DROP FUNCTION IF EXISTS finance.fn_broker_csv_profiles();
