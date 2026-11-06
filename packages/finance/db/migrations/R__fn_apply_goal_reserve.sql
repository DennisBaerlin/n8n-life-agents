-- ============================================================
-- fn_apply_goal_reserve (SPARZIEL-TOPF SETZEN)
--   Der Topf eines Sparziels ist das Zielkonto seiner Sparrate (recurring_payments.target_account_id). Die RESERVE ist
--   der Topf plus jedes Konto, auf dem noch getaggtes Geld des Ziels liegt (Paket DB-ist-das-Gesetz Nachtrag D).
--   Familie: fn_goal_reserve_accounts / fn_goal_reserve_account_reason / fn_goal_reserve_reason / fn_apply_goal_reserve;
--   Konsumenten: fn_book_savings_goal_transfer, fn_set_savings_goal.
--   Setzt den Topf auf die Raten-Zeile des Ziels (auch eine beendete: das Wiedereroeffnen kopiert ihr Zielkonto, und
--   der Topf bleibt die Adresse fuer Einzahlungen) und auf ALLE noch laufenden Zeilen der Raten-Kette
--   (fn_recurring_lineage; nach einer Raten-Aenderung laeuft die Vorgaengerzeile bis zum Stichtag weiter).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_apply_goal_reserve(p_goal int, p_account int)
RETURNS void
LANGUAGE sql
AS $$
    UPDATE finance.recurring_payments rp SET target_account_id = p_account
      FROM finance.savings_goals g
     WHERE g.id = p_goal AND g.recurring_payment_id IS NOT NULL
       AND (rp.id = g.recurring_payment_id
            OR (rp.id IN (SELECT finance.fn_recurring_lineage(g.recurring_payment_id))
                AND (rp.valid_to IS NULL OR rp.valid_to > core.fn_today())));
$$;
