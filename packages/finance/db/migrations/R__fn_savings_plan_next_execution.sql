-- ============================================================
-- fn_savings_plan_next_execution (READ) -- naechste offene Ausfuehrung eines Sparplans (Audit Paket 2, Punkt 3)
--   EINE Quelle fuer die HITL-Karte (tool_book_savings_plan_execution, Read-Node) UND die Buchung
--   (fn_book_savings_plan_execution) -> Karte = Buchung. Sucht das frueheste offene Vorkommen (fn_recurring_due_open
--   bis heute) ueber ALLE Glieder der Vorgaenger-Kette des Plans: nach einer Betragsaenderung mit Stichtag in der
--   Zukunft liegt die noch anstehende Ausfuehrung auf der ALTEN rp (alter Betrag) -> sie wird mit genau dieser rp
--   und ihrem Betrag geliefert.
--   Eingabe jsonb: savings_plan_name.
--   RUECKGABE: {ok:true, savings_plan_id, symbol, security_name, due_date, recurring_payment_id, plan_amount (>0),
--   settlement_account_id, currency (des Verrechnungskontos)} | {ok:false, reason} (nicht gefunden, mehrdeutig,
--   nicht aktiv, kein offenes Vorkommen).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_plan_next_execution(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_name    TEXT := p->>'savings_plan_name';
    v_resolve RECORD;
    v_plan    finance.savings_plans%ROWTYPE;
    v_occ     RECORD;
BEGIN
    SELECT r.id, r.hit_count INTO v_resolve
    FROM finance.fn_resolve_savings_plan(v_name, FALSE) r;
    IF v_resolve.hit_count = 0 THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'No savings plan found matching "' || v_name || '".');
    END IF;
    IF v_resolve.hit_count > 1 THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Multiple savings plans match "' || v_name || '". Please be more specific.',
            'hit_count', v_resolve.hit_count);
    END IF;

    SELECT * INTO v_plan FROM finance.savings_plans WHERE id = v_resolve.id;
    IF v_plan.status <> 'active' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'Savings plan "' || v_plan.name || '" is ' || v_plan.status || '. Only active plans can be executed.');
    END IF;

    SELECT o.due_date, o.recurring_payment_id, abs(rp.amount) AS plan_amount, rp.account_id, a.currency
    INTO v_occ
    FROM finance.fn_recurring_due_open(CURRENT_DATE) o
    JOIN finance.recurring_payments rp ON rp.id = o.recurring_payment_id
    JOIN finance.accounts a ON a.id = rp.account_id
    WHERE o.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_plan.recurring_payment_id))
    ORDER BY o.due_date, o.recurring_payment_id
    LIMIT 1;

    IF v_occ.due_date IS NULL THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'No open occurrence found for savings plan "' || v_plan.name
                   || '". Either already booked for this period or not yet due.');
    END IF;

    RETURN jsonb_build_object('ok', true,
        'savings_plan_id',       v_plan.id,
        'symbol',                v_plan.symbol,
        'security_name',         v_plan.security_name,
        'due_date',              v_occ.due_date,
        'recurring_payment_id',  v_occ.recurring_payment_id,
        'plan_amount',           v_occ.plan_amount,
        'settlement_account_id', v_occ.account_id,
        'currency',              v_occ.currency);
END;
$$;
