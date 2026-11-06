-- ============================================================
-- fn_recurring_occurrence_amount (READ) -- der Betrag, den fn_book_recurring_occurrence fuer ein Vorkommen bucht
--   EINE Quelle fuer den Soll-Betrag im Monats-Check (fn_statement_match) UND die Buchung (Audit Paket 2,
--   Punkt 9 + Plan-Review "Karte = Buchung"). Signiert wie recurring_payments.amount.
--   Regel: Kreditrate (rp-Kette gehoert einem Kredit) und die geplante Rate wuerde den Kredit ueberzahlen
--   (letzte, kleinere Rate) -> der Abloesebetrag aus fn_get_loan_payment_split (Restschuld + Zins); sonst der
--   geplante Betrag der rp. Unbekannte rp -> NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_occurrence_amount(p_rp_id int, p_due date)
RETURNS numeric LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_amount NUMERIC;
    v_loan   INT;
    v_split  JSONB;
BEGIN
    SELECT amount INTO v_amount FROM finance.recurring_payments WHERE id = p_rp_id;
    IF v_amount IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT id INTO v_loan FROM finance.loans
    WHERE recurring_payment_id = finance.fn_recurring_lineage_head(p_rp_id);
    IF v_loan IS NOT NULL THEN
        v_split := finance.fn_get_loan_payment_split(jsonb_build_object(
            'loan_id', v_loan, 'payment_amount', abs(v_amount), 'payment_date', p_due,
            'due_date', p_due, 'recurring_payment_id', p_rp_id));
        IF (v_split->>'ok')::boolean IS DISTINCT FROM true
           AND COALESCE((v_split->>'payoff_amount')::numeric, 0) > 0 THEN
            RETURN -(v_split->>'payoff_amount')::numeric;
        END IF;
    END IF;

    RETURN v_amount;
END;
$$;
