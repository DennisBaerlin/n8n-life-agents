-- ============================================================
-- fn_close_insurance (ATOMIC WRITE) -- Smart-Close (analog fn_close_savings_plan)
--   Zaehlt Transaktionen mit recurring_payment_id = insurance.recurring_payment_id.
--   v_tx_count = 0 -> Hard-DELETE: Police + verknuepfte RP entfernt (Karteileiche,
--     keine Historie). FK-Reihenfolge: Versicherung zuerst (FK ins->rp RESTRICT), dann RP.
--   v_tx_count > 0 -> Soft-Close: insurance.status='cancelled' + valid_to=CURRENT_DATE;
--     RP.status='paused' + valid_to=CURRENT_DATE (Cashflow-Posten endet, Historie bleibt).
--   Eingabe jsonb: insurance_name.
--   RUECKGABE: {ok:true, action:'deleted'|'closed', tx_count}. RAISE fuer echte
--   Ausnahmen (nicht gefunden / mehrdeutig -> Tool/Agent loest vorher auf).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT := p->>'insurance_name';
    v_ins       finance.insurances%ROWTYPE;
    v_resolve   RECORD;
    v_tx_count  INT;
BEGIN
    -- Aufloesen (auch nicht-aktive koennen geschlossen/entfernt werden)
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_insurance(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Insurance "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple insurances match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_ins FROM finance.insurances WHERE id = v_resolve.id;

    -- Buchungen zaehlen (NULL-rp -> 0 -> Hard-DELETE)
    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions
    WHERE recurring_payment_id = v_ins.recurring_payment_id;

    IF v_tx_count = 0 THEN
        -- Hard-DELETE: erst Police (FK RESTRICT ins->rp), dann RP (falls vorhanden)
        DELETE FROM finance.insurances WHERE id = v_ins.id;
        IF v_ins.recurring_payment_id IS NOT NULL THEN
            DELETE FROM finance.recurring_payments WHERE id = v_ins.recurring_payment_id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'tx_count', 0);
    ELSE
        -- Soft-Close: Police kuendigen + RP beenden (taucht nicht mehr in Cashflow/due_open auf)
        UPDATE finance.insurances
        SET status = 'cancelled', valid_to = CURRENT_DATE
        WHERE id = v_ins.id;

        IF v_ins.recurring_payment_id IS NOT NULL THEN
            UPDATE finance.recurring_payments
            SET status = 'paused', valid_to = CURRENT_DATE
            WHERE id = v_ins.recurring_payment_id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'closed', 'tx_count', v_tx_count);
    END IF;
END;
$$;
