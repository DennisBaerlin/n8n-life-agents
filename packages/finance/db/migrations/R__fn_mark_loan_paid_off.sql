-- ============================================================
-- fn_mark_loan_paid_off (INTERNAL HELPER — not tool-facing)
--   Der EINE Uebergang "Kredit abbezahlt" (Audit Paket 2, Punkt 9; zweiter Konsument -> vereinheitlicht):
--   loans.status='paid_off' + die Raten-rp (Kopf der Kette) endet (status='paused', valid_to = p_end; ein frueheres
--   vertragliches Ende bleibt). Der Vorzustand landet in loans.settled_from (status, rp_id, rp_status, rp_valid_to,
--   paid_off_on) -> fn_void_transaction stellt ihn exakt her, sobald nach einem Storno wieder Restschuld besteht.
--   Gerufen von fn_settle_loan (p_end = Abloesedatum) und fn_book_loan_payment (p_end = Tag nach der letzten Rate).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_mark_loan_paid_off(p_loan_id int, p_end date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_loan finance.loans%ROWTYPE;
    v_rp   finance.recurring_payments%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM finance.loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found.', p_loan_id;
    END IF;
    SELECT * INTO v_rp FROM finance.recurring_payments WHERE id = v_loan.recurring_payment_id;

    UPDATE finance.loans
    SET status = 'paid_off',
        settled_from = jsonb_build_object(
            'status',      v_loan.status,
            'rp_id',       v_loan.recurring_payment_id,
            'rp_status',   v_rp.status,
            'rp_valid_to', v_rp.valid_to,
            'paid_off_on', p_end)
    WHERE id = p_loan_id;

    IF v_loan.recurring_payment_id IS NOT NULL THEN
        UPDATE finance.recurring_payments
        SET status = 'paused', valid_to = LEAST(COALESCE(valid_to, p_end), p_end)
        WHERE id = v_loan.recurring_payment_id;
    END IF;
END;
$$;
