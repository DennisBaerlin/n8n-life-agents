-- ============================================================
-- fn_goal_reserve_account_reason (KONTO-REGEL FUER EINEN SPARZIEL-TOPF)
--   Die eine Adresse der Konto-Regel eines Sparziel-Topfs: aktives cash-/Tagesgeld- oder Festgeldkonto (kein Depot,
--   Kredit oder geschlossenes Konto) und nicht das Abbuchungskonto der Rate (p_funding; NULL = ohne Rate).
--   Familie: fn_goal_reserve_accounts / fn_goal_reserve_reason / fn_apply_goal_reserve; Konsumenten:
--   fn_create_savings_goal (Ziel existiert noch nicht), fn_goal_reserve_reason, fn_book_savings_goal_transfer.
--   -> NULL | Grund.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_reserve_account_reason(p_account int, p_funding int)
RETURNS text
LANGUAGE sql
STABLE
AS $$
    SELECT CASE
        WHEN NOT EXISTS (SELECT 1 FROM finance.accounts
                         WHERE id = p_account AND status = 'active' AND account_type IN ('cash', 'fixed_deposit'))
            THEN 'The savings account must be an active cash/Tagesgeld or fixed-deposit account (not a depot, loan or closed account).'
        WHEN p_account = p_funding
            THEN 'Reserve account must differ from the funding (debit) account.'
    END;
$$;
