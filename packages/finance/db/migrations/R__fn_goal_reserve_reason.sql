-- ============================================================
-- fn_goal_reserve_reason (REGEL FUER EINEN NEUEN SPARZIEL-TOPF)
--   Der Topf eines Sparziels ist das Zielkonto seiner Sparrate (recurring_payments.target_account_id). Die RESERVE ist
--   der Topf plus jedes Konto, auf dem noch getaggtes Geld des Ziels liegt (Paket DB-ist-das-Gesetz Nachtrag D).
--   Familie: fn_goal_reserve_accounts / fn_goal_reserve_account_reason / fn_goal_reserve_reason / fn_apply_goal_reserve;
--   Konsumenten: fn_book_savings_goal_transfer, fn_set_savings_goal.
--   -> NULL | Grund: Konto-Regel (fn_goal_reserve_account_reason), dann: das Ziel hat eine Sparrate.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_reserve_reason(p_goal int, p_account int)
RETURNS text
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_rp      INT;
    v_funding INT;
BEGIN
    SELECT g.recurring_payment_id, rp.account_id INTO v_rp, v_funding
      FROM finance.savings_goals g LEFT JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
     WHERE g.id = p_goal;
    IF v_rp IS NULL THEN
        RETURN COALESCE(finance.fn_goal_reserve_account_reason(p_account, NULL),
                        'This goal has no savings rate to route into a reserve account.');
    END IF;
    RETURN finance.fn_goal_reserve_account_reason(p_account, v_funding);
END;
$$;
