-- ============================================================
-- fn_goal_reserve_accounts (RESERVE-KONTEN EINES SPARZIELS)
--   Der Topf eines Sparziels ist das Zielkonto seiner Sparrate (recurring_payments.target_account_id). Die RESERVE ist
--   der Topf plus jedes saldo-basierte Konto (fn_goal_pot_account_types), auf dem noch Geld des Ziels liegt — getaggt
--   ODER zugeordnet (savings_goal_account_share, Sparziel-Zweckbindung 2026-10-27). Depot-Anteile gehoeren NICHT dazu:
--   aus einem Depot kann keine Geldbewegung abgehen (Umschichten = Verkauf mit Ziel).
--   Familie: fn_goal_reserve_accounts / fn_goal_reserve_reason / fn_apply_goal_reserve; Konsumenten:
--   fn_book_savings_goal_transfer, fn_set_savings_goal.
--   -> (account_id, share, is_pot): Topf (auch mit Anteil 0) + Konten mit Anteil > 0; share = Anteil in Kontowaehrung.
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
        SELECT s.account_id, s.share_native AS share
          FROM finance.savings_goal_account_share s
         WHERE s.goal_id = p_goal AND s.account_type = ANY (finance.fn_goal_pot_account_types())
    )
    SELECT COALESCE(s.account_id, pot.id), COALESCE(s.share, 0), (pot.id IS NOT NULL AND COALESCE(s.account_id, pot.id) = pot.id)
      FROM shares s FULL JOIN pot ON pot.id = s.account_id
     WHERE COALESCE(s.share, 0) > 0 OR pot.id IS NOT NULL;
$$;
