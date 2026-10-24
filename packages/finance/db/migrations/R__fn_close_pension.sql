-- ============================================================
-- fn_close_pension (ATOMIC WRITE) -- Smart-Close (analog fn_close_savings_plan)
--   Zaehlt Transaktionen mit recurring_payment_id = pension.recurring_payment_id
--   (rp ist optional -> ohne rp immer 0 -> Hard-DELETE).
--   v_tx_count = 0 -> Hard-DELETE: Pension + ggf. verknuepfte RP (Karteileiche).
--     FK-Reihenfolge: Pension zuerst (FK pension->rp), dann RP.
--   v_tx_count > 0 -> Soft-Close: pension.status='paused'; RP.status='paused' +
--     valid_to=CURRENT_DATE (Beitrag endet im Cashflow, Historie bleibt).
--   Eingabe jsonb: pension_name.
--   RUECKGABE: {ok:true, action:'deleted'|'closed', tx_count}. RAISE fuer echte
--   Ausnahmen (nicht gefunden / mehrdeutig).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_pension(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT := p->>'pension_name';
    v_pension   finance.pension%ROWTYPE;
    v_resolve   RECORD;
    v_tx_count  INT;
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_pension(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Pension "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple pensions match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_pension FROM finance.pension WHERE id = v_resolve.id;

    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions
    WHERE recurring_payment_id = v_pension.recurring_payment_id;

    IF v_tx_count = 0 THEN
        -- Hard-DELETE: erst Pension (FK pension->rp), dann RP (falls vorhanden)
        DELETE FROM finance.pension WHERE id = v_pension.id;
        IF v_pension.recurring_payment_id IS NOT NULL THEN
            DELETE FROM finance.recurring_payments WHERE id = v_pension.recurring_payment_id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'tx_count', 0);
    ELSE
        -- Soft-Close: Pension pausieren + RP beenden
        UPDATE finance.pension
        SET status = 'paused'
        WHERE id = v_pension.id;

        IF v_pension.recurring_payment_id IS NOT NULL THEN
            UPDATE finance.recurring_payments
            SET status = 'paused', valid_to = CURRENT_DATE
            WHERE id = v_pension.recurring_payment_id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'closed', 'tx_count', v_tx_count);
    END IF;
END;
$$;
