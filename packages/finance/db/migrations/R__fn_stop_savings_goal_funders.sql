-- ============================================================
-- fn_stop_savings_goal_funders (ATOMIC WRITE) — Phase S WS-B Stufe 3
--   Lebenszyklus-Ereignis "ERREICHT" (Owner-Korrektur "erreicht != ausgegeben"): das Ziel ist voll
--   gefuellt, soll aber NICHT abgeschlossen oder freigegeben werden — der Owner will nur die laufenden
--   BEITRAEGE stoppen. Diese fn pausiert ALLE Quellen eines Ziels und laesst Ziel + Reserve UNBERUEHRT.
--
--   STOPPT ueber die MENGE der Quellen (nie "die" rp hartkodiert):
--     (a) die Cash-Rate (savings_goals.recurring_payment_id), falls vorhanden;
--     (b) ALLE verknuepften Sparplaene (savings_plans.savings_goal_id = goal) — Plan-Status='paused'
--         UND deren recurring_payment (Verrechnungskonto-Cash-Abbuchung) paused.
--   Jede pausierte recurring_payment bekommt valid_to=CURRENT_DATE (endet im Cashflow; Historie bleibt).
--
--   LAESST UNBERUEHRT: savings_goals.status (bleibt 'active' — voll gefuellt, wartet auf Verwendung),
--     das Reserve-Journal (savings_goal_reserve_entries) und jeden Bestand (depot_holdings). NIE automatisch
--     aufgerufen — nur auf Owner-Wunsch ueber den set-Pfad (tool_set_savings_goal stop_funders=true).
--
--   Eingabe jsonb: goal_id (im n8n/Aufrufer aufgeloest).
--   RUECKGABE: {ok:true, goal_id, paused_cash_rate (bool), paused_plan_count (int)} — Post-State-Zaehler.
--   RAISE nur bei nicht gefunden (Aufrufer hat das Ziel schon validiert -> echte Ausnahme).
--   Anwenden via: db_apply.ps1 -File packages\finance\db\migrations\R__fn_stop_savings_goal_funders.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_stop_savings_goal_funders(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_id        INT := NULLIF(p->>'goal_id', '')::int;
    v_rp_cash   INT;
    v_paused_cash BOOLEAN := false;
    v_plan_cnt  INT := 0;
BEGIN
    SELECT recurring_payment_id INTO v_rp_cash FROM finance.savings_goals WHERE id = v_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Savings goal % not found.', v_id;
    END IF;

    -- (a) Cash-Rate pausieren (falls vorhanden)
    IF v_rp_cash IS NOT NULL THEN
        UPDATE finance.recurring_payments
        SET status = 'paused', valid_to = CURRENT_DATE
        WHERE id = v_rp_cash;
        v_paused_cash := true;
    END IF;

    -- (b) ALLE verknuepften Sparplaene + deren recurring_payments pausieren (Menge der Quellen)
    UPDATE finance.recurring_payments rp
    SET status = 'paused', valid_to = CURRENT_DATE
    FROM finance.savings_plans sp
    WHERE sp.recurring_payment_id = rp.id AND sp.savings_goal_id = v_id;

    WITH stopped AS (
        UPDATE finance.savings_plans
        SET status = 'paused'
        WHERE savings_goal_id = v_id
        RETURNING 1
    )
    SELECT count(*)::int INTO v_plan_cnt FROM stopped;

    RETURN jsonb_build_object(
        'ok', true,
        'goal_id', v_id,
        'paused_cash_rate', v_paused_cash,
        'paused_plan_count', v_plan_cnt);
END;
$$;
