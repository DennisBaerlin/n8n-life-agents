-- ============================================================
-- fn_account_free_balance (READ, STABLE) — freier Saldo eines saldo-basierten Kontos
--   Saldo minus die Anteile AKTIVER Sparziele auf dem Konto (getaggte Buchungen + Zuordnungen,
--   savings_goal_account_share.share_native, Kontowaehrung). Die eine Adresse des Freier-Saldo-Guards
--   (YNAB/Firefly: Summe der Zuordnungen <= Kontostand) fuer fn_book_savings_reservation und fn_create_savings_goal.
--   Depot/Kredit (kein saldo-basiertes Konto, fn_goal_pot_account_types) -> NULL. Kann negativ sein (Saldo unter die
--   Zuordnungen gefallen = account_reserve_status.breach).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_free_balance(p_account int)
RETURNS numeric
LANGUAGE sql
STABLE
AS $$
    SELECT COALESCE(b.balance, 0)
           - COALESCE((SELECT sum(s.share_native) FROM finance.savings_goal_account_share s
                       WHERE s.account_id = a.id AND s.goal_status = 'active'), 0)
    FROM finance.accounts a
    LEFT JOIN finance.account_balances b ON b.account_id = a.id
    WHERE a.id = p_account AND a.account_type = ANY (finance.fn_goal_pot_account_types());
$$;
