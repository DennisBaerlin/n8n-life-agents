-- ============================================================
-- fn_reconcile_open_due (READ, STABLE) -- die offenen Vorkommen, die ein Saldo-Abgleich zum Stichtag als erledigt
--   markiert (Monats-Check WP-A): Dauerauftrags-Vorkommen des Kontos (Quelle oder Transfer-Ziel) mit Faelligkeit
--   <= Stichtag - 10 Tage und Zins-Vorkommen mit value_date <= Stichtag - 10. EINE Adresse fuer fn_reconcile_account
--   (Skip-Write) und die Karte von tool_reconcile_account (2026-10-23: Hinweis "n offene Vorkommen werden als erledigt
--   markiert" — ein Depot-Verrechnungskonto mit offener Sparplan-Ausfuehrung verlor sonst still die Kauf-Erinnerung).
--   RUECKGABE TABLE(recurring_payment_id, due_date, interest_period_end) — je Zeile genau eine Art gesetzt.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_reconcile_open_due(p_account_id int, p_date date)
RETURNS TABLE (recurring_payment_id int, due_date date, interest_period_end date)
LANGUAGE plpgsql STABLE AS $$   -- plpgsql: spaete Bindung (R__fn_recurring_due_open laeuft alphabetisch danach)
BEGIN
    RETURN QUERY
    SELECT o.recurring_payment_id, o.due_date, NULL::date
    FROM finance.fn_recurring_due_open(DATE '1900-01-01', p_date - 10) o
    JOIN finance.recurring_payments r ON r.id = o.recurring_payment_id
    WHERE r.account_id = p_account_id OR r.target_account_id = p_account_id
    UNION ALL
    SELECT NULL::int, NULL::date, i.period_end
    FROM finance.fn_interest_due_open(p_date - 10) i
    WHERE i.account_id = p_account_id;
END;
$$;
