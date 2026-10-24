-- V002__rename_payment_and_credit_to_schedule.sql
-- Versionierte Einmal-Migration (Flyway-V__): vereinheitlicht die Zahl-/Gutschrift-Rhythmus-Spalten
-- auf EINEN kanonischen Prefix schedule_* (Enforcement Phase 5e). Vorher drifteten drei Prefixe fuer
-- dasselbe interval/unit/day_of_month-Konzept:
--   finance_loans:                  payment_interval/payment_unit/payment_day_of_month
--   finance_account_interest_rates: credit_interval/credit_unit/credit_day_of_month
--   finance_recurring_payments + finance_insurances: schedule_* (schon kanonisch -> unberuehrt)
-- Der geteilte ENUM heisst bereits finance.schedule_unit; schedule_* ist damit der etablierte
-- Oberbegriff. finance_recurring_payments/finance_insurances tragen schedule_* schon -> nur die
-- beiden anderen Tabellen werden umbenannt.
--
-- KEINE BEGIN/COMMIT (der Treiber wrapt jede Migration in EINE Transaktion). Pro Spalte geguardet ->
-- idempotenz-aequivalent: fresh DB hat schedule_* schon (CREATE TABLE in finance.init.sql) ->
-- jeder Block ist dort ein No-op; bestehende DB mit der Altspalte -> RENAME. Kein Tabellen-Existenz-
-- Guard noetig (Baseline-Inits laufen davor). Keine GENERATED-Spalte/View haengt an diesen Spalten
-- (loans-GENERATED nutzen interest_rate/principal_rate; recurring monthly_equivalent nutzt schedule_*;
-- finance_loan_overview selektiert sie nicht) -> reiner RENAME, kein DROP/ADD.

DO $$ BEGIN
    -- finance_loans: payment_* -> schedule_*
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'payment_interval')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'schedule_interval') THEN
        ALTER TABLE finance.loans RENAME COLUMN payment_interval TO schedule_interval;
    END IF;
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'payment_unit')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'schedule_unit') THEN
        ALTER TABLE finance.loans RENAME COLUMN payment_unit TO schedule_unit;
    END IF;
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'payment_day_of_month')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_loans'
                    AND column_name = 'schedule_day_of_month') THEN
        ALTER TABLE finance.loans RENAME COLUMN payment_day_of_month TO schedule_day_of_month;
    END IF;

    -- finance_account_interest_rates: credit_* -> schedule_*
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'credit_interval')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'schedule_interval') THEN
        ALTER TABLE finance.account_interest_rates RENAME COLUMN credit_interval TO schedule_interval;
    END IF;
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'credit_unit')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'schedule_unit') THEN
        ALTER TABLE finance.account_interest_rates RENAME COLUMN credit_unit TO schedule_unit;
    END IF;
    IF    EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'credit_day_of_month')
      AND NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'agent' AND table_name = 'finance_account_interest_rates'
                    AND column_name = 'schedule_day_of_month') THEN
        ALTER TABLE finance.account_interest_rates RENAME COLUMN credit_day_of_month TO schedule_day_of_month;
    END IF;
END $$;
