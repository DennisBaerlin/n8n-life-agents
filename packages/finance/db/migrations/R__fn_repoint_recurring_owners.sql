-- ============================================================
-- fn_repoint_recurring_owners (INTERNAL HELPER — not tool-facing)
--   Kopf-Regel der Vorgaenger-Kette: nach einem Split oder Reopen zeigen alle
--   Besitzer-Entitaeten von der alten auf die neue recurring_payment. Eine Stelle fuer alle Besitzer-Tabellen
--   (loans, savings_goals, savings_plans, insurances, pension) plus bank_todos.head_id -> sonst zeigte z. B. ein
--   Kredit nach set_recurring_payment weiter auf die alte rp (Erinnerung stempelte falsch, Rate wiederholte sich endlos).
--   Eingabe: p_old, p_new (recurring_payment-ids). Rueckgabe: void.
--   Gerufen von fn_split_recurring_payment und fn_reopen_recurring_payment.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_repoint_recurring_owners(p_old int, p_new int)
RETURNS void LANGUAGE plpgsql AS $$
BEGIN
    UPDATE finance.loans         SET recurring_payment_id = p_new WHERE recurring_payment_id = p_old;
    UPDATE finance.savings_goals SET recurring_payment_id = p_new WHERE recurring_payment_id = p_old;
    UPDATE finance.savings_plans SET recurring_payment_id = p_new WHERE recurring_payment_id = p_old;
    UPDATE finance.insurances    SET recurring_payment_id = p_new WHERE recurring_payment_id = p_old;
    UPDATE finance.pension       SET recurring_payment_id = p_new WHERE recurring_payment_id = p_old;
    UPDATE finance.bank_todos    SET head_id = p_new WHERE head_id = p_old;
END;
$$;
