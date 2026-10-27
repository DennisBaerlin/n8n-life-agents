-- ============================================================
-- fn_goal_end_transfer (INTERNAL HELPER — Livebefund 2026-10-27, nicht tool-facing)
--   Beendet einen Dauerauftrag, den eine Ziel-Rate ab p_first fortfuehrt (fn_create_savings_goal, fn_set_savings_goal):
--   alle noch laufenden Glieder seiner Kette bekommen valid_to = p_first (exklusiv), der Status bleibt 'active' -> ein
--   noch nicht gebuchter, faelliger Termin VOR p_first bleibt offen (Erinnerung/Monats-Check buchen ihn wie sonst);
--   ab p_first zaehlt nur die Ziel-Rate (nichts doppelt). Hat er nie gegolten (p_first <= valid_from) und keine Buchung
--   in der Kette, wird er geloescht (keine leere Zeile).
--   RUECKGABE: 'deleted' | 'ended'.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_end_transfer(p_rp_id int, p_first date)
RETURNS text LANGUAGE plpgsql AS $$
BEGIN
    IF p_first <= (SELECT valid_from FROM finance.recurring_payments WHERE id = p_rp_id)
       AND NOT EXISTS (SELECT 1 FROM finance.transactions t
                       WHERE t.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_rp_id))) THEN
        DELETE FROM finance.recurring_payments WHERE id = p_rp_id;
        RETURN 'deleted';
    END IF;
    UPDATE finance.recurring_payments
    SET valid_to = GREATEST(valid_from, p_first)
    WHERE id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
      AND (valid_to IS NULL OR valid_to > p_first);
    RETURN 'ended';
END;
$$;
