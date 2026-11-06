-- ============================================================
-- fn_close_savings_plan (ATOMIC WRITE)
--   Smart-Close-Guard (analog fn_close_account): zaehlt Transaktionen auf ALLEN rps der Vorgaenger-Kette des
--   Plans (fn_recurring_lineage; Audit Paket 2, Punkt 2 -- vorher nur auf der aktuellen rp: nach einem Betrags-
--   Split wurde ein Plan mit Historie hart geloescht).
--   v_tx_count = 0 -> Hard-DELETE: Plan + alle rps der Kette entfernt (Karteileiche, keine Historie).
--   Soft-Close beendet ALLE noch laufenden Glieder der Kette (fn_end_recurring_chain).
--   v_tx_count > 0 -> Soft-Close: RP.valid_to = CURRENT_DATE, plan.status = 'paused'
--   (Buchungshistorie bleibt erhalten; Plan taucht nicht mehr in fn_recurring_due_open auf).
--   Eingabe jsonb: savings_plan_name.
--   RUECKGABE: {ok:true, action:'deleted'|'closed', tx_count}. RAISE fuer echte
--   Ausnahmen (nicht gefunden).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_savings_plan(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT := p->>'savings_plan_name';
    v_plan      finance.savings_plans%ROWTYPE;
    v_resolve   RECORD;
    v_tx_count  INT;
    v_chain     INT[];
BEGIN
    -- Plan aufloesen (auch paused Plaene koennen geschlossen werden)
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_savings_plan(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Savings plan "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple savings plans match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_plan FROM finance.savings_plans WHERE id = v_resolve.id;

    -- Buchungen ueber die ganze Kette zaehlen (Entscheidung Hard-DELETE vs. Soft-Close)
    v_chain := ARRAY(SELECT finance.fn_recurring_lineage(v_plan.recurring_payment_id));
    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions
    WHERE recurring_payment_id = ANY(v_chain);

    IF v_tx_count = 0 THEN
        -- Hard-DELETE: erst Plan (FK RESTRICT plan->rp), dann alle Ketten-rps in EINEM Statement (predecessor-FK
        -- NO ACTION prueft am Statement-Ende)
        DELETE FROM finance.savings_plans        WHERE id = v_plan.id;
        DELETE FROM finance.recurring_payments   WHERE id = ANY(v_chain);

        RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'tx_count', 0);
    ELSE
        -- Soft-Close: ALLE noch laufenden Glieder der Kette beenden (auch eine alte rp mit noch anstehender
        -- Ausfuehrung, Audit Paket 2) -> nichts taucht mehr in fn_recurring_due_open auf; Plan pausieren.
        PERFORM finance.fn_end_recurring_chain(v_plan.recurring_payment_id, CURRENT_DATE);

        UPDATE finance.savings_plans
        SET status = 'paused'
        WHERE id = v_plan.id;

        RETURN jsonb_build_object('ok', true, 'action', 'closed', 'tx_count', v_tx_count);
    END IF;
END;
$$;
