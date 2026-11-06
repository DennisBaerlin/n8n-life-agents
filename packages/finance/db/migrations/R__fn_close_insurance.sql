-- ============================================================
-- fn_close_insurance (ATOMIC WRITE)
--   Smart-Close einer Versicherung: ohne gebuchten Beitrag -> Hard-DELETE (Fehlanlage), sonst Soft-Close (Kuendigung).
--   KETTEN-FEST (WP2 "Finanzen schlank"): nach einer Beitragsaenderung traegt die Police mehrere Glieder -- Buchungen
--   zaehlen ueber die ganze Kette (fn_recurring_lineage), Hard-DELETE loescht die ganze Kette in EINEM Statement
--   (Vorgaenger-FK NO ACTION), Soft-Close beendet alle noch laufenden Glieder (fn_end_recurring_chain). Das Vertragsende
--   steht nur an der Kette (die Police traegt seit finance:V027 kein valid_to).
--   Eingabe jsonb: insurance_name (Aufloesung ueber fn_resolve_insurance, auch nicht aktive).
--   RUECKGABE: {ok:true, action:'deleted'|'closed', tx_count} | {ok:false, code:'not_found'|'ambiguous', reason, candidates}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_insurance(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name     TEXT := p->>'insurance_name';
    v_resolve  RECORD;
    v_ins      finance.insurances%ROWTYPE;
    v_tx_count INT;
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

    -- Buchungen ueber die ganze Beitrags-Kette zaehlen (ohne Kette -> 0 -> Hard-DELETE)
    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions
    WHERE recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_ins.recurring_payment_id));

    IF v_tx_count = 0 THEN
        -- Hard-DELETE: erst Police (FK ins->rp), dann die ganze Kette (falls vorhanden)
        DELETE FROM finance.insurances WHERE id = v_ins.id;
        IF v_ins.recurring_payment_id IS NOT NULL THEN
            DELETE FROM finance.recurring_payments
             WHERE id IN (SELECT finance.fn_recurring_lineage(v_ins.recurring_payment_id));
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'tx_count', 0);
    ELSE
        -- Soft-Close: Police kuendigen + Kette beenden (taucht nicht mehr in Cashflow/due_open auf)
        UPDATE finance.insurances SET status = 'cancelled' WHERE id = v_ins.id;
        PERFORM finance.fn_end_recurring_chain(v_ins.recurring_payment_id, CURRENT_DATE);

        RETURN jsonb_build_object('ok', true, 'action', 'closed', 'tx_count', v_tx_count);
    END IF;
END;
$$;
