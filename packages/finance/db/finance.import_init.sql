-- ============================================================
-- Bulk-Import — Staging-Schicht (Phase 2 Onboarding-Plan)
-- Zweck:   propose -> review -> commit: Extraktion (Vision/Chat/CSV) landet als ROHE Rows
--          in finance_import_staging; fn_import_validate prueft je Row (Pflichtfelder,
--          Enums, Dubletten-Backstop, Referenz-Aufloesung inkl. In-Batch-Konten);
--          Korrekturen passieren VOR dem HITL-Gate per Chat (fn_import_update_row, kein
--          eigenes Gate — Staging ist keine Domaenen-Daten); der Commit laeuft als EIN
--          atomarer fn_import_bundle-Aufruf (Loop ueber die BESTEHENDEN fn_create_*/
--          fn_book_* = die getestete Validierungs-Oberflaeche; all-or-nothing pro Batch).
--
-- Payload-Vertrag (ROHE Nutzer-Werte, NAMEN statt IDs — die Bundle-fn loest auf;
-- das LLM/Vision extrahiert nur Rohwerte, nie Abgeleitetes):
--   account:           name*, account_type* (nicht loan), bank, account_number, currency, owner_person,
--                      settlement_account (Name; Pflicht bei *_depot), opening_balance
--                      (-> Eroeffnungsbuchung in fn_create_account; nicht bei Depots), interest_rate, ...
--   stock_buy:         depot* (Name), symbol (Pflicht ohne ISIN = Krypto; sonst Kennung = ISIN, fn_holding_symbol),
--                      shares*, price_per_share* (Einstand), isin (Pflicht bei stocks_depot), name, order_fee (def 0),
--                      transaction_date (def heute), depot_number/depot_holder (gedruckt -> fn_import_resolve_depot)
--                      -> Bestandsuebernahme (existing_position): Verrechnungskonto-Saldo bleibt
--   insurance:         name*, annual_premium*, debit_account* (Name, EUR), first_payment_date*,
--                      insurance_company, policy_number, policyholder_person,
--                      schedule_unit (def year)/interval/day_of_month, valid_from (Rate leitet die DB ab)
--   pension:           name*, pension_type*, provider, current_value, contract_number, owner_person,
--                      contribution_amount (+ debit_account & first_payment_date Pflicht),
--                      schedule_day_of_month, retirement_start_date, ...
--   recurring_payment: name*, direction* (income|expense), amount*, account* (Name),
--                      schedule_unit*, first_payment_date*, schedule_interval/day, valid_from/to
--   real_estate:       name*, current_value*, owner_person, notes, value_updated_at
--   savings_goal:      name*, target_amount*, account* (Name), reserve_account* (Name, Sparkonto/Topf, ≠ account),
--                      first_payment_date*, beneficiary_person,
--                      GENAU EINES von {target_date, monthly_savings_rate}, goal_type, ...
--   loan:              name*, original_amount*, interest_rate*, debit_account* (Name, EUR),
--                      disbursement_date*, monthly_annuity (+ first_payment_date Pflicht),
--                      current_balance (Restschuld heute, 0 < x <= original), borrower_person,
--                      lender, schedule_day_of_month, disbursement_account (Name; nur frischer Kredit),
--                      real_estate (Name), interest_rate_fixed_until
--   Personen-Felder: Name aus dem Haushalt (fn_import_resolve_persons), leer = Haushalt.
--
-- Usage:   db_apply.ps1 -File packages\finance\db\finance.import_init.sql
-- ============================================================

CREATE SCHEMA IF NOT EXISTS finance;

-- Phase-3a Schema-Extraktion (idempotent): bestehende agent.finance_import_staging -> finance.import_staging.
-- Fresh-DB: no-op; Bestands-DB: verschiebt die echten Staging-Daten vor dem CREATE ... IF NOT EXISTS (kein Verlust).
DO $$ BEGIN
    IF to_regclass('agent.finance_import_staging') IS NOT NULL AND to_regclass('finance.import_staging') IS NULL THEN
        ALTER TABLE agent.finance_import_staging SET SCHEMA finance;
        ALTER TABLE finance.finance_import_staging RENAME TO import_staging;
    END IF;
END $$;

CREATE TABLE IF NOT EXISTS finance.import_staging (
    id               serial PRIMARY KEY,
    batch_id         uuid NOT NULL,
    row_no           int  NOT NULL,
    entity_type      text NOT NULL,
    payload          jsonb NOT NULL DEFAULT '{}'::jsonb,
    status           text NOT NULL DEFAULT 'staged'
                         CHECK (status IN ('staged','valid','invalid','committed')),
    validation_error text,
    source           text NOT NULL DEFAULT 'chat' CHECK (source IN ('chat','vision','csv')),
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (batch_id, row_no)
);

-- entity_type-CHECK als DROP+ADD (Migration: pension_statement kam nach v1 dazu;
-- der auto-benannte Spalten-CHECK der Erstanlage wird mit-gedroppt)
ALTER TABLE finance.import_staging DROP CONSTRAINT IF EXISTS finance_import_staging_entity_type_check;
ALTER TABLE finance.import_staging DROP CONSTRAINT IF EXISTS finance_import_staging_entity_type_chk;
ALTER TABLE finance.import_staging ADD CONSTRAINT finance_import_staging_entity_type_chk
    CHECK (entity_type IN
        ('account','stock_buy','insurance','pension','recurring_payment',
         'real_estate','savings_goal','loan','pension_statement'));

-- Kein separater (batch_id, row_no)-Index: die UNIQUE (batch_id, row_no) oben legt bereits
-- einen deckenden Index an (redundant entfernt -> packages/finance/db/migrations/V004__drop_redundant_import_staging_index.sql).

-- updated_at via gemeinsamen Touch-Helper (idempotent mit-definiert, standalone-faehig)
CREATE OR REPLACE FUNCTION finance.touch_updated_at()
RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN NEW.updated_at := NOW(); RETURN NEW; END; $$;

DROP TRIGGER IF EXISTS trg_finance_import_staging_touch ON finance.import_staging;
CREATE TRIGGER trg_finance_import_staging_touch
    BEFORE UPDATE ON finance.import_staging
    FOR EACH ROW EXECUTE FUNCTION finance.touch_updated_at();

-- Lesepfad: finance_ro liest diese Tabelle ueber den breiten Schema-Grant, den die Host-fn
-- core.fn_provision_package_roles('finance') erteilt (GRANT SELECT ON ALL TABLES IN SCHEMA finance).
-- KEIN GRANT in Paket-SQL (Paket-Lese-Vertrag: Deklaration vs. Ausfuehrung — Rechte vergibt NUR die
-- privilegierte Host-fn, nie das Paket; docs/package-contract.md).
