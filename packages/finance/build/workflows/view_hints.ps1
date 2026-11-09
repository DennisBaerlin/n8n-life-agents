#Requires -Version 5.1
# Dot-gesourct von build.ps1 (Def-Discovery nimmt jede Datei unter build/workflows/; reine Daten + zwei Helfer, kein Build-*).
# --- Spalten-Spickzettel fuer postgres_select (Befunde KW 45, Fund 10) ---
# 8 Fehlabfragen in einer Woche: das Modell nahm natuerliche Namen (depot_name, goal_name, account_id, account_name) aus der
# falschen Ansicht. Diese EINE Liste (Ansicht -> exakte Spaltennamen, bei Verwechslungsgefahr mit Bedeutung) geht in die
# Tool-Beschreibung von postgres_select beider Agenten (agent.finance + agent.finance_advisor).
# Drift-Schutz (beide hart): tests/db/finance/test_view_column_hints.sql prueft jede Spalte gegen information_schema
# (der Block "-- hint:" dort ist eine Kopie dieser Liste), scripts/contract_lint.ps1 (Check 31) prueft Mengengleichheit
# Liste <-> Test-Block. Bewusste Ausnahme von "keine Spaltenliste im Prompt" (packages/CLAUDE.md Build-Gotchas).
# Format je Eintrag: 'spalte' ODER 'spalte = Bedeutung'. Keine Apostrophe/Backticks/geschweifte Doppelklammern (Description-Parser).
function Get-FinanceViewHints {
    [ordered]@{
        'account_overview'               = @('id', 'name = account name', 'account_type', 'balance', 'currency', 'status', 'settlement_account_id', 'balance_eur', 'label = sign plus name, for replies only')
        'depot_holdings_overview'        = @('id = holding_id', 'account_id = the depot id', 'account_name = the DEPOT name', 'name = the position (security) name', 'isin', 'symbol', 'shares', 'book_value', 'market_value', 'market_value_eur', 'price_as_of')
        'savings_goal_progress'          = @('id', 'name = goal name', 'target_amount', 'current_amount', 'progress_percent', 'status')
        'active_recurring_payments'      = @('id', 'name', 'account_id', 'target_account_id', 'amount', 'rhythm', 'monthly_equivalent', 'last_valid_day')
        'upcoming_recurring_payments'    = @('id', 'name', 'account_id', 'amount', 'rhythm', 'starts_on', 'last_valid_day', 'counted_in_cashflow')
        'monthly_cashflow_overview'      = @('id', 'name', 'account_id', 'account_name', 'monthly_equivalent_eur', 'cashflow_class', 'starts_on', 'last_valid_day')
        'pension_overview'               = @('id', 'name', 'provider', 'owner', 'current_value', 'monthly_contribution', 'status')
        'savings_plan_overview'          = @('id', 'name', 'depot_name', 'settlement_account_name', 'savings_goal_name', 'amount_per_execution', 'monthly_amount', 'next_execution')
        'standing_order_overview'        = @('name', 'kind', 'from_account', 'to_account', 'amount_per_execution', 'rhythm', 'monthly_amount', 'starts_on', 'last_execution', 'last_valid_day', 'executed_by = bank|manual|unknown: who makes the transfer (manual = the user transfers it themselves, no standing order at a bank)')
        'account_funding_overview'       = @('account_id', 'account_name', 'state', 'min_projected', 'runs_out_on')
        'account_reserve_status'         = @('account_id', 'account_name', 'balance', 'reserved', 'shortfall', 'breach')
        'depot_reserve_status'           = @('account_id', 'account_name', 'market_value', 'reserved', 'shortfall', 'breach', 'fx_missing')
        'savings_goal_reserve_breakdown' = @('goal_id', 'source', 'account_id', 'account_name', 'reserved_amount')
        'depot_performance'              = @('depot_name', 'is_total', 'return_pa_pct', 'return_since_start_pct', 'takeover_start_date', 'price_stale', 'missing_reason')
        'account_everyday_spending'      = @('account_id', 'account_name', 'has_history', 'everyday_per_day', 'everyday_per_month')
        'loan_overview'                  = @('id', 'name', 'lender', 'current_remaining_debt', 'monthly_annuity', 'status')
        'active_insurances'              = @('id', 'name', 'insurance_company', 'annual_premium', 'account_name', 'last_valid_day')
        'real_estate_overview'           = @('id', 'name', 'current_value', 'associated_debt', 'net_equity')
    }
}

# Spalten-Namen ohne Bedeutung (fuer Lint/Test): je Ansicht die reinen Spaltennamen.
function Get-FinanceViewHintColumns {
    $out = [ordered]@{}
    foreach ($kv in (Get-FinanceViewHints).GetEnumerator()) {
        $out[$kv.Key] = @($kv.Value | ForEach-Object { ($_ -split ' = ', 2)[0] })
    }
    $out
}

# Der Abschnitt der postgres_select-Description (Englisch, Modell-Instruktion).
function Get-FinanceViewHintsText {
    $parts = foreach ($kv in (Get-FinanceViewHints).GetEnumerator()) { "finance.$($kv.Key)($($kv.Value -join ', '))" }
    'COLUMN CHEAT SHEET (exact names; the name columns differ per view (depot_name, goal_name, account_name exist only where listed here), for a view not listed SELECT * first; active_recurring_payments carries ids only, join finance.accounts for account names; there is no table finance.pensions, use finance.pension_overview): ' + ($parts -join '; ') + '. Columns not listed: SELECT * or information_schema.columns. END DATES: last_valid_day = last day still valid (inclusive), empty = no end, rarely a payment date; last_execution = date of the last payment of a standing order (empty next to a last_valid_day = not known, do not work it out); valid_to = first day no longer valid, never quote it as an end date.'
}
