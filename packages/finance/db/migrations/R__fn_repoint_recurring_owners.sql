-- ============================================================
-- fn_repoint_recurring_owners (INTERNAL HELPER — not tool-facing)
--   Kopf-Regel der Vorgaenger-Kette (Audit Paket 2, A0): nach einem Split oder Reopen zeigen ALLE
--   Besitzer-Entitaeten von der alten auf die neue recurring_payment. EINE Stelle fuer alle Besitzer-Tabellen
--   (loans, savings_goals, savings_plans, insurances, pension) -> vorher zeigte z. B. ein Kredit nach
--   set_recurring_payment weiter auf die alte rp (Erinnerung stempelte falsch, Rate wiederholte sich endlos).
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
END;
$$;
