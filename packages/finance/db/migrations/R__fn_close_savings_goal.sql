-- ============================================================
-- fn_close_savings_goal (ATOMIC WRITE) -- Smart-Close (analog fn_close_savings_plan)
--   WS-B Stufe 3 (Phase S, Owner-Korrektur "erreicht != ausgegeben"): zwei DISTINKTE Abschluss-Ausgaenge,
--   gesteuert ueber den Input `outcome` ('completed' | 'cancelled', Default 'cancelled'):
--     * ERFUELLT  (outcome='completed'): das Geld wurde AUSGEGEBEN -> die Reserve ist real entnommen.
--       GUARD: completed nur wenn die Reserve ~0 ist (savings_goal_progress.current_amount, |.| <= 0.01)
--       ODER `force`=true ("trotz Restbetrag schliessen"). Completion gibt die Reserve NICHT selbst frei
--       (sie ist da schon ausgegeben). Sonst {ok:false} (kein stilles Auto-Freigeben zweckgebundenen Gelds).
--     * ABGEBROCHEN (outcome='cancelled'): das Ziel wird verworfen -> die ZUORDNUNGEN werden FREI, der
--       freigewordene Betrag ist reassignbar. Bestand bleibt IMMER (RESTRICT, hier nie beruehrt).
--
--   Zaehlt Transaktionen mit recurring_payment_id in der Vorgaenger-Kette der Rate (Audit Paket 2: nach einer
--   Reaktivierung liegt die Historie auf der alten rp) ODER savings_goal_id = goal.id
--   (WS-A: getaggte Einmal-/Entnahme-/Umschicht-Tx ohne Rate-rp zaehlen ebenfalls); bei outcome='completed' auch
--   Journal-Zeilen des Ziels (Zuordnung, 2026-10-27: Erfuellungs-Historie). Ohne jede Tx/Zeile -> Hard-DELETE.
--   v_tx_count = 0 -> Hard-DELETE: Sparziel + ggf. verknuepfte RP. Das Reserve-Journal geht per ON DELETE
--     CASCADE (savings_goal_id) automatisch mit; transactions.savings_goal_id + savings_plans.savings_goal_id
--     per ON DELETE SET NULL (die Buchungen/Sparplaene selbst bleiben, nur die Zuordnung faellt). FK-Reihenfolge:
--     Goal zuerst (FK goal->rp), dann RP.
--   v_tx_count > 0 -> Soft-Close: goal.status=outcome; RP.status='paused' + valid_to=CURRENT_DATE (Sparrate
--     endet im Cashflow, Historie bleibt). Bei outcome='cancelled' zusaetzlich: die getaggten Cash-Buchungen
--     werden freigegeben (transactions.savings_goal_id SET NULL = Historie bleibt, Euros reassignbar) und die
--     verknuepften Sparplaene entkoppelt (savings_plans.savings_goal_id SET NULL). Bei outcome='completed'
--     bleiben Tags/Sparplaene als Erfuellungs-Historie ("dahin ging das Geld"). Das append-only Reserve-Journal
--     wird bei Soft-Close NICHT mutiert (append-only-Invariante); der status<>'active'-Filter der Deckungs-Views
--     schliesst die Reserve eines geschlossenen Ziels ohnehin aus.
--   Eingabe jsonb: savings_goal_name, outcome (opt, Default 'cancelled'), force (opt bool, Default false).
--   RUECKGABE: {ok:true, action:'deleted'|'closed', status, tx_count} ODER {ok:false, reason, current_amount}.
--   RAISE fuer echte Ausnahmen (nicht gefunden / mehrdeutig).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_close_savings_goal(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_name      TEXT := p->>'savings_goal_name';
    v_completed BOOLEAN := lower(COALESCE(NULLIF(p->>'outcome', ''), 'cancelled')) = 'completed';
    v_force     BOOLEAN := COALESCE(NULLIF(p->>'force', '')::boolean, false);
    v_status    finance.goal_status;
    v_goal      finance.savings_goals%ROWTYPE;
    v_resolve   RECORD;
    v_tx_count  INT;
    v_current   NUMERIC;
    v_chain     INT[];
BEGIN
    SELECT r.id, r.hit_count, r.candidates INTO v_resolve
    FROM finance.fn_resolve_savings_goal(v_name, FALSE) r;

    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'not_found',
            'reason', 'Savings goal "' || COALESCE(v_name, '') || '" not found - ask the user for the exact name.', 'candidates', '[]'::jsonb);
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false, 'code', 'ambiguous',
            'reason', 'Multiple savings goals match "' || v_name || '" - ask the user which one (candidates).', 'candidates', v_resolve.candidates);
    END IF;

    SELECT * INTO v_goal FROM finance.savings_goals WHERE id = v_resolve.id;
    v_status := CASE WHEN v_completed THEN 'completed' ELSE 'cancelled' END::finance.goal_status;

    -- ERFUELLT-Gate: completed nur wenn die Reserve ~0 ist (real ausgegeben) ODER force. Sonst {ok:false}
    -- (kein stilles Auto-Freigeben des reservierten, aber noch nicht verwendeten Betrags).
    IF v_completed AND NOT v_force THEN
        SELECT current_amount INTO v_current FROM finance.savings_goal_progress WHERE id = v_goal.id;
        v_current := COALESCE(v_current, 0);
        IF abs(v_current) > 0.01 THEN
            RETURN jsonb_build_object('ok', false,
                'reason', 'Goal "' || v_goal.name || '" still holds a reserve of '
                       || to_char(v_current, 'FM999999990D00') || ' that has not been spent. Withdraw/spend it '
                       || 'first (then it completes), or confirm closing despite the remaining balance.',
                'current_amount', v_current);
        END IF;
    END IF;

    -- WS-A: Rate-Tx UND getaggte Reserve-Bewegungen zaehlen. NULL-rp explizit behandelt (Finding #6):
    -- bei recurring_payment_id IS NULL faellt der erste Zweig auf false -> nur der savings_goal_id-Zweig zaehlt.
    -- COUNT zaehlt ZEILEN: die Raten-Haben-Tx traegt beide Felder -> wird einmal gezaehlt (keine Doppelzaehlung).
    -- Audit Paket 2: Rate-Tx ueber die GANZE Vorgaenger-Kette (nach Reaktivierung liegt die Historie auf der alten rp).
    -- Sparziel-Zweckbindung 2026-10-27: bei ERFUELLT sind auch Journal-Zeilen (Zuordnung ohne Buchung) Historie -> ein
    -- erfuelltes Ziel, das nur zugeordnetes Geld hatte, schliesst WEICH (Status sichtbar) statt zu verschwinden. Ein
    -- ABGEBROCHENES Ziel ohne Buchung bleibt Hard-DELETE (es floss kein Geld; die Zuordnung faellt per CASCADE).
    v_chain := ARRAY(SELECT finance.fn_recurring_lineage(v_goal.recurring_payment_id));
    SELECT COUNT(*) INTO v_tx_count
    FROM finance.transactions
    WHERE recurring_payment_id = ANY(v_chain)
       OR savings_goal_id = v_goal.id;
    IF v_completed THEN
        v_tx_count := v_tx_count + (SELECT COUNT(*) FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal.id);
    END IF;

    IF v_tx_count = 0 THEN
        -- Hard-DELETE: erst Goal (Journal CASCADE; tags/plans SET NULL; FK goal->rp), dann alle Ketten-rps
        DELETE FROM finance.savings_goals WHERE id = v_goal.id;
        DELETE FROM finance.recurring_payments WHERE id = ANY(v_chain);

        RETURN jsonb_build_object('ok', true, 'action', 'deleted', 'status', v_status::text, 'tx_count', 0);
    ELSE
        -- Soft-Close: Ziel auf completed/cancelled + RP beenden
        UPDATE finance.savings_goals
        SET status = v_status
        WHERE id = v_goal.id;

        IF v_goal.recurring_payment_id IS NOT NULL THEN
            PERFORM finance.fn_end_recurring_chain(v_goal.recurring_payment_id, CURRENT_DATE);
        END IF;

        -- ABGEBROCHEN: Zuordnungen freigeben (Historie bleibt) -> der Betrag ist reassignbar. Bei ERFUELLT
        -- bleiben Tags/Sparplaene als Erfuellungs-Historie. Das append-only Journal wird nicht mutiert (der
        -- status<>'active'-Filter der Deckungs-Views entkoppelt die Depot-Reserve ohnehin).
        IF NOT v_completed THEN
            UPDATE finance.transactions SET savings_goal_id = NULL WHERE savings_goal_id = v_goal.id;
            UPDATE finance.savings_plans SET savings_goal_id = NULL WHERE savings_goal_id = v_goal.id;
        END IF;

        RETURN jsonb_build_object('ok', true, 'action', 'closed', 'status', v_status::text, 'tx_count', v_tx_count);
    END IF;
END;
$$;
