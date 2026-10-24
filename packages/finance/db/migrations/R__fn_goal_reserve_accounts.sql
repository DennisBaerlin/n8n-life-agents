-- ============================================================
-- fn_goal_reserve_accounts (RESERVE-KONTEN EINES SPARZIELS)
--   Der Topf eines Sparziels ist das Zielkonto seiner Sparrate (recurring_payments.target_account_id). Die RESERVE ist
--   der Topf plus jedes Konto, auf dem noch getaggtes Geld des Ziels liegt (Paket DB-ist-das-Gesetz Nachtrag D).
--   Familie: fn_goal_reserve_accounts / fn_goal_reserve_reason / fn_apply_goal_reserve; Konsumenten:
--   fn_book_savings_goal_transfer, fn_set_savings_goal.
--   -> (account_id, share, is_pot): Topf (auch mit Anteil 0) + Konten mit Anteil > 0; share = Summe der getaggten
--   Cash-Buchungen des Ziels auf dem Konto (Kontowaehrung).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_reserve_accounts(p_goal int)
RETURNS TABLE (account_id int, share numeric, is_pot boolean)
LANGUAGE sql
STABLE
AS $$
    WITH pot AS (
        SELECT rp.target_account_id AS id
          FROM finance.savings_goals g JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
         WHERE g.id = p_goal AND rp.target_account_id IS NOT NULL
    ), shares AS (
        SELECT t.account_id, sum(t.amount) AS share
          FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
         WHERE t.savings_goal_id = p_goal AND a.account_type IN ('cash', 'fixed_deposit')
         GROUP BY t.account_id
    )
    SELECT COALESCE(s.account_id, pot.id), COALESCE(s.share, 0), (pot.id IS NOT NULL AND COALESCE(s.account_id, pot.id) = pot.id)
      FROM shares s FULL JOIN pot ON pot.id = s.account_id
     WHERE COALESCE(s.share, 0) > 0 OR pot.id IS NOT NULL;
$$;
