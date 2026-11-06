-- ============================================================
-- fn_delete_loan (ATOMIC WRITE) -- Hard-DELETE einer Kredit-Fehlanlage (Inverse von create_loan)
--   NUR fuer eine versehentlich angelegte Kredit-Konstruktion ohne gebuchte Raten. Ein echter,
--   bedienter Kredit wird NICHT geloescht -> {ok:false} (settle_loan zum Abloesen, set_loan fuer
--   status=refinanced). Loescht (Inverse von create_loan): Disbursement-Beine (Eroeffnung + ggf.
--   Auszahlung, via loan_id), Loan-Stammdaten, verknuepfte Rate-rp, balance-Zeile + das dedizierte
--   Loan-Konto. Debit-/Disbursement-Konto (echte Konten des Nutzers) bleiben unangetastet.
--   KORRIGIERBAR (kein RAISE): >=1 gebuchte Rate (category loan_payment/principal/settlement)
--     -> {ok:false, reason, repayment_count}.
--   Eingabe jsonb: loan_name. Resolve findet auch paused (Fehlanlagen ohne Annuitaet).
--   RUECKGABE: {ok:true, action:'deleted', loan_id, loan_account_id}. RAISE nur bei not-found / mehrdeutig.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_delete_loan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name    TEXT := p->>'loan_name';
    v_resolve RECORD;
    v_loan    finance.loans%ROWTYPE;
    v_cnt     INT;
BEGIN
    SELECT r.loan_id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_loan(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Loan "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple loans match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_loan FROM finance.loans WHERE id = v_resolve.loan_id;

    -- Korrigierbar: bereits bediente Raten -> {ok:false} (Disbursement-Beine sind ok zu loeschen).
    SELECT COUNT(*) INTO v_cnt FROM finance.transactions
    WHERE loan_id = v_loan.id AND category IN ('loan_payment','principal','settlement');
    IF v_cnt > 0 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'This loan has ' || v_cnt || ' booked repayment(s) and cannot be deleted. '
                   || 'Use settle_loan to pay it off, or set_loan to mark it refinanced.',
            'repayment_count', v_cnt);
    END IF;

    -- Clean (nur Disbursement-Beine). Reihenfolge FK-sicher:
    -- 1. alle Tx des Kredits (Eroeffnung + ggf. Auszahlung; Trigger rechnen Giro-/Loan-Saldo neu)
    DELETE FROM finance.transactions WHERE loan_id = v_loan.id;
    -- 2. Loan-Stammdaten (loest FK loan->rp + loan->Konten)
    DELETE FROM finance.loans WHERE id = v_loan.id;
    -- 3. die ganze Raten-Kette (jetzt referenzfrei; WP2: nach einer Ratenaenderung mehrere Glieder -- EIN Statement,
    --    der Vorgaenger-FK ist NO ACTION und wird erst am Statement-Ende geprueft)
    IF v_loan.recurring_payment_id IS NOT NULL THEN
        DELETE FROM finance.recurring_payments
         WHERE id IN (SELECT finance.fn_recurring_lineage(v_loan.recurring_payment_id));
    END IF;
    -- 4. balance-Zeile des Loan-Kontos (kein CASCADE) + 5. das dedizierte Loan-Konto selbst
    DELETE FROM finance.account_balances WHERE account_id = v_loan.loan_account_id;
    DELETE FROM finance.accounts WHERE id = v_loan.loan_account_id;

    RETURN jsonb_build_object('ok', true, 'action', 'deleted',
        'loan_id', v_loan.id, 'loan_account_id', v_loan.loan_account_id);
END;
$$;
