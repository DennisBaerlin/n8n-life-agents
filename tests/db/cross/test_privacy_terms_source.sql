-- tests/db/cross/test_privacy_terms_source.sql
-- scripts/lib/privacy_terms.sql (Quelle von refresh_privacy_denylist.ps1) laeuft gegen das aktuelle Schema. Faengt Spalten-
-- Drift: eine umbenannte Spalte liesse die Liste sonst still veralten. Die Datei druckt Zeilen, sie schreibt nichts; die
-- Zeilen landen im Testlog, darum laeuft sie hier auf einer Datenbank ohne Fixture-Werte in diesen Tabellen.
BEGIN;
SET LOCAL default_transaction_read_only = on;
\ir ../../../scripts/lib/privacy_terms.sql
ROLLBACK;
