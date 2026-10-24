-- ============================================================
-- fn_import_allowed_keys (READ, IMMUTABLE) -- die Felder, die eine Import-Zeile je entity_type tragen darf
--   = genau die Felder, die die Bestaetigungskarte dieser Art zeigt (Owner 2026-10-22: was nicht auf der Karte
--   steht, wird nicht gespeichert). fn_import_bundle reicht den Payload sonst ungesehen an fn_create_*/fn_book_*
--   weiter. provider_symbol einer Depot-Position setzt tool_commit_import aus der Yahoo-Aufloesung der ISIN und die
--   Karte zeigt es (Monats-Check WP-G). depot_number/depot_holder sind die GEDRUCKTEN Depot-Angaben
--   (fn_import_resolve_depot/fn_import_depot_conflict; die Nummer speichert der Commit an einem Depot ohne Nummer,
--   die Karte zeigt das). fn_import_validate_row macht jedes andere Feld
--   zum Zeilenfehler. Der Build gleicht diese Listen mit den Kartenzeilen ab (packages/finance/build/workflows/
--   hitl_lines.ps1, Test-FinanceImportKeysCovered) -> EINE Zeile je Typ im Format WHEN '<typ>' THEN ARRAY[...].
--   RUECKGABE text[] (NULL = unbekannter Typ).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_allowed_keys(p_type text)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_type
        WHEN 'account' THEN ARRAY['name','account_type','bank','account_number','settlement_account','owner_person','currency','opening_balance','interest_rate','interest_credit_unit','interest_credit_interval','interest_credit_day_of_month','interest_posting_day_of_month','interest_day_count_convention','interest_auto_post','interest_valid_from','fixed_deposit_maturity_date','fixed_deposit_auto_renew']
        WHEN 'stock_buy' THEN ARRAY['depot','symbol','isin','name','shares','price_per_share','order_fee','quote_currency','asset_class','transaction_date','provider_symbol','provider_currency','depot_number','depot_holder']
        WHEN 'insurance' THEN ARRAY['name','insurance_company','policy_number','policyholder_person','annual_premium','schedule_unit','schedule_interval','schedule_day_of_month','debit_account','valid_from','first_payment_date','insurance_type','coverage_amount','beneficiary','claim_deadline_hours']
        WHEN 'pension' THEN ARRAY['name','pension_type','provider','contract_number','owner_person','current_value','value_updated_at','guaranteed_monthly_pension','retirement_start_date','contribution_amount','debit_account','first_payment_date','schedule_day_of_month','notes']
        WHEN 'pension_statement' THEN ARRAY['pension','statement_date','reached_claim','projection','em_monthly','is_nominal','notes']
        WHEN 'recurring_payment' THEN ARRAY['name','account','direction','amount','schedule_unit','schedule_interval','schedule_day_of_month','first_payment_date','valid_from','valid_to','notes']
        WHEN 'real_estate' THEN ARRAY['name','current_value','value_updated_at','owner_person','status','notes']
        WHEN 'savings_goal' THEN ARRAY['name','goal_type','target_amount','target_date','monthly_savings_rate','account','reserve_account','schedule_day_of_month','first_payment_date','beneficiary_person','priority','notes']
        WHEN 'loan' THEN ARRAY['name','lender','borrower_person','original_amount','current_balance','disbursement_date','interest_rate','principal_rate','interest_rate_fixed_until','monthly_annuity','first_payment_date','schedule_day_of_month','debit_account','disbursement_account','real_estate']
    END;
$$;
