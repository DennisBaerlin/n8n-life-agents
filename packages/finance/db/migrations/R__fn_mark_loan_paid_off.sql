-- ============================================================
-- fn_mark_loan_paid_off (INTERNAL HELPER — not tool-facing)
--   Der EINE Uebergang "Kredit abbezahlt" (Audit Paket 2, Punkt 9; zweiter Konsument -> vereinheitlicht):
--   loans.status='paid_off' + die GANZE Raten-Kette endet (status='paused', valid_to = p_end; ein frueheres
--   vertragliches Ende bleibt; WP2: nach einer Ratenaenderung mit kuenftigem Stichtag liefe sonst ein Glied weiter). Der Vorzustand landet in loans.settled_from (status, chain = [{id, status, valid_to}] je Glied,
--   paid_off_on) -> fn_void_transaction stellt ihn exakt her, sobald nach einem Storno wieder Restschuld besteht.
--   Gerufen von fn_settle_loan (p_end = Abloesedatum) und fn_book_loan_payment (p_end = Tag nach der letzten Rate).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_mark_loan_paid_off(p_loan_id int, p_end date)
RETURNS void LANGUAGE plpgsql AS $$
DECLARE
    v_loan finance.loans%ROWTYPE;
BEGIN
    SELECT * INTO v_loan FROM finance.loans WHERE id = p_loan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Loan % not found.', p_loan_id;
    END IF;

    UPDATE finance.loans
    SET status = 'paid_off',
        settled_from = jsonb_build_object(
            'status',      v_loan.status,
            'chain',       COALESCE((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'status', r.status, 'valid_to', r.valid_to)
                                                      ORDER BY r.id)
                                     FROM finance.recurring_payments r
                                     WHERE r.id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id))),
                                    '[]'::jsonb),
            'paid_off_on', p_end)
    WHERE id = p_loan_id;

    -- Ende exakt p_end (auch vor valid_from eines erst spaeter beginnenden Glieds = leerer Bereich): die Rate gilt bis zum
    -- Abzahlungstag, ein frueheres vertragliches Ende bleibt.
    UPDATE finance.recurring_payments
       SET status = 'paused', valid_to = LEAST(COALESCE(valid_to, p_end), p_end)
     WHERE id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id))
       AND (valid_to IS NULL OR valid_to > p_end OR status <> 'paused');
END;
$$;
