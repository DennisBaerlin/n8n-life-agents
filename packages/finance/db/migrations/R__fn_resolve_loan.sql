-- ============================================================
-- fn_resolve_loan
--   Loan-Name → IDs + Stammdaten fuer Kreditraten-Buchung.
--   Mehrdeutigkeit wird wie bei Accounts via hit_count gemeldet. monthly_annuity = Rate des heute gueltigen Glieds der
--   Raten-Kette (WP2: die Kopie am Kredit entfiel mit finance:V026; Spaltenname consumer-stabil).
--   p_active_only: default TRUE -> nur status='active' (book_loan_payment/settle_loan);
--   FALSE -> auch paused/paid_off (delete_loan findet Fehlanlagen, settle/sell geben
--   freundliche {ok:false} bei bereits beendeten Entitaeten statt RAISE).
-- ============================================================
-- Alte 1-Arg-Signatur droppen: die neue (TEXT, BOOLEAN DEFAULT TRUE) ist sonst ein zweiter
-- Overload und ein 1-Arg-Aufruf wird mehrdeutig ("function is not unique").
DROP FUNCTION IF EXISTS finance.fn_resolve_loan(text);
-- Rueckgabe-Spalte monthly_principal (Ursprungs-Tilgung, ungelesen) entfiel mit finance:V025 -> geaenderter
-- RETURNS TABLE verlangt DROP + CREATE (CREATE OR REPLACE kann den Rueckgabetyp nicht aendern).
DROP FUNCTION IF EXISTS finance.fn_resolve_loan(text, boolean);

CREATE OR REPLACE FUNCTION finance.fn_resolve_loan(
    p_name        text,
    p_active_only boolean DEFAULT TRUE
) RETURNS TABLE (
    loan_id           int,
    loan_account_id   int,
    debit_account_id  int,
    monthly_annuity   numeric,
    hit_count         int,
    candidates        jsonb
) LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_count INT;
    v_cand  JSONB;
    v_exact BOOLEAN;
BEGIN
    FOREACH v_exact IN ARRAY ARRAY[TRUE, FALSE] LOOP
    SELECT
        COUNT(*),
        jsonb_agg(jsonb_build_object(
            'loan_id',         l.id,
            'name',            l.name,
            'lender',          l.lender,
            'status',          l.status,
            'monthly_annuity', (SELECT abs(r.amount) FROM finance.recurring_payments r
                                WHERE r.id = finance.fn_recurring_current(l.recurring_payment_id, current_date))
        ) ORDER BY l.id)
    INTO v_count, v_cand
    FROM finance.loans l
    WHERE finance.fn_name_matches(l.name, p_name, v_exact) AND (p_active_only = FALSE OR l.status = 'active');
    EXIT WHEN v_count > 0;
    END LOOP;

    IF v_count = 1 THEN
        RETURN QUERY
        SELECT
            l.id,
            l.loan_account_id,
            l.debit_account_id,
            (SELECT abs(r.amount) FROM finance.recurring_payments r
              WHERE r.id = finance.fn_recurring_current(l.recurring_payment_id, current_date)),
            1,
            v_cand
        FROM finance.loans l
        WHERE finance.fn_name_matches(l.name, p_name, v_exact) AND (p_active_only = FALSE OR l.status = 'active');
    ELSE
        RETURN QUERY SELECT
            NULL::INT, NULL::INT, NULL::INT, NULL::NUMERIC,
            COALESCE(v_count, 0),
            COALESCE(v_cand, '[]'::jsonb);
    END IF;
END;
$$;
