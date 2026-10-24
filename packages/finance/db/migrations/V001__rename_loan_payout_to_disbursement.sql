-- V001__rename_loan_payout_to_disbursement.sql
-- Versionierte Einmal-Migration (Flyway-V__): benennt finance_loans.payout_account_id ->
-- disbursement_account_id auf BESTEHENDEN DBs um. Geshippt in 5d (commit 1dc4d90) als
-- geguardeter In-Init-Block, weil die Apply-Ketten frueher Inits VOR Migrationen fuhren und
-- der finance_loan_overview-View (damals im Init) die Spalte sofort brauchte. Seit der
-- Umstellung auf das Flyway-Modell (Baseline-Inits -> V__ -> R__-Repeatables) liegt der View
-- in db/migrations/R__finance_views.sql und laeuft NACH dieser Migration -> der Rename gehoert
-- jetzt korrekt hierher.
--
-- KEINE BEGIN/COMMIT (der Treiber wrapt jede Migration in EINE Transaktion). Geguardet ->
-- idempotenz-aequivalent: fresh DB hat die Spalte schon als disbursement_account_id
-- (CREATE TABLE in finance.init.sql) -> dieser Block ist dort ein No-op; bestehende DB
-- mit der Altspalte -> RENAME. Kein Tabellen-Existenz-Guard noetig (Baseline laeuft davor).

DO $$ BEGIN
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'payout_account_id')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'disbursement_account_id') THEN
        ALTER TABLE finance.loans RENAME COLUMN payout_account_id TO disbursement_account_id;
    END IF;
END $$;
