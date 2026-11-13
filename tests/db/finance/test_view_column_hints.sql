-- ============================================================
-- test_view_column_hints -- der Spalten-Spickzettel von postgres_select nennt nur echte Spalten--   Die Description von postgres_select (agent.finance + agent.finance_advisor) enthaelt aus
--   packages/finance/build/workflows/view_hints.ps1 je Ansicht die exakten Spaltennamen. Dieser Test prueft jede dort
--   genannte Ansicht/Spalte gegen information_schema -- wird eine Spalte umbenannt, ist er rot. Die Zeilen zwischen
--   view-hints:begin/end sind eine Kopie der Liste (der Test kann die PS-Datei nicht lesen); scripts/contract_lint.ps1
--   (Check 31) prueft Mengengleichheit Liste <-> Kopie, damit beide nicht auseinanderlaufen.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_line TEXT;
    v_view TEXT;
    v_col  TEXT;
    v_n    INT := 0;
BEGIN
    FOR v_line IN SELECT unnest(ARRAY[
        -- view-hints:begin
        'account_overview|id, name, account_type, balance, currency, status, settlement_account_id, balance_eur, label',
        'depot_holdings_overview|id, account_id, account_name, name, isin, symbol, shares, book_value, market_value, market_value_eur, price_as_of',
        'savings_goal_progress|id, name, target_amount, current_amount, progress_percent, status',
        'active_recurring_payments|id, name, account_id, target_account_id, amount, rhythm, monthly_equivalent, last_valid_day',
        'upcoming_recurring_payments|id, name, account_id, amount, rhythm, starts_on, last_valid_day, counted_in_cashflow',
        'monthly_cashflow_overview|id, name, account_id, account_name, monthly_equivalent_eur, cashflow_class, starts_on, last_valid_day',
        'pension_overview|id, name, provider, owner, current_value, monthly_contribution, status',
        'savings_plan_overview|id, name, depot_name, settlement_account_name, savings_goal_name, amount_per_execution, monthly_amount, next_execution',
        'standing_order_overview|name, kind, from_account, to_account, amount_per_execution, rhythm, monthly_amount, starts_on, last_execution, last_valid_day, executed_by',
        'account_funding_overview|account_id, account_name, state, min_projected, runs_out_on',
        'account_reserve_status|account_id, account_name, balance, reserved, shortfall, breach',
        'depot_reserve_status|account_id, account_name, market_value, reserved, shortfall, breach, fx_missing',
        'savings_goal_reserve_breakdown|goal_id, source, account_id, account_name, reserved_amount',
        'depot_performance|depot_name, is_total, return_pa_pct, return_since_start_pct, takeover_start_date, price_stale, missing_reason',
        'account_everyday_spending|account_id, account_name, has_history, everyday_per_day, everyday_per_month',
        'loan_overview|id, name, lender, current_remaining_debt, monthly_annuity, status',
        'active_insurances|id, name, insurance_company, annual_premium, account_name, last_valid_day',
        'real_estate_overview|id, name, current_value, associated_debt, net_equity'
        -- view-hints:end
    ]) LOOP
        v_view := split_part(v_line, '|', 1);
        FOREACH v_col IN ARRAY string_to_array(split_part(v_line, '|', 2), ', ') LOOP
            v_n := v_n + 1;
            IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                           WHERE table_schema = 'finance' AND table_name = v_view AND column_name = v_col) THEN
                RAISE EXCEPTION 'FAIL [view_hints]: finance.%.% gibt es nicht - view_hints.ps1 und diesen Test nachziehen', v_view, v_col;
            END IF;
        END LOOP;
    END LOOP;
    IF v_n < 50 THEN RAISE EXCEPTION 'FAIL [view_hints]: nur % Spalten geprueft - Liste leer?', v_n; END IF;
    RAISE NOTICE 'PASS [view_hints: % Spalten existieren]', v_n;
END $$;
ROLLBACK;
