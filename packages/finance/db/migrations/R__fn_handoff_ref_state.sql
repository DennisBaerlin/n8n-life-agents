-- ============================================================
-- fn_handoff_ref_state (READ, STABLE) -- heutiger Stand einer Sache, die eine vereinbarte Plan-Aufgabe betrifft
--   Die eine Lese-Adresse fuer den Vergleich "vereinbart gegen heute" (finance.fn_handoff_diff) und "bisher gegen neu" auf
--   der Eintrags-Karte (finance.fn_with_handoff). Nur die Felder, die finance.fn_handoff_tool_spec unter state nennt.
--   Eingabe: p_type (savings_goal | savings_plan | recurring_payment | pension), p_id (id wie in entered_refs; bei einer
--   Raten-Kette jedes Glied: gelesen wird das neueste nicht leere Glied, finance.fn_handoff_rp_latest, damit eine
--   vereinbarte kuenftige Aenderung schon als eingetragen gilt).
--   Rueckgabe: {name, currency, <feld>: Rohwert} oder NULL (Sache geloescht, unbekannte Art). Betraege positiv,
--   valid_to = letzter gueltiger Tag (inklusiv, finance.fn_recurring_last_valid_day), day = schedule_day_of_month,
--   account / to_account = Kontoname von Quelle und Ziel. Ziel- und Vorsorge-Betraege stehen in EUR.
--   Tests: tests/db/finance/test_fn_handoff_diff.sql
-- ============================================================
-- fn_handoff_rp_latest: neuestes nicht leeres Glied der Raten-Kette von p_rp_id (Ordnung wie fn_recurring_last_valid_day:
-- ein leeres Glied [x,x) entsteht beim Kuerzen einer Kette und traegt keinen Betrag). NULL bei NULL/unbekannt.
CREATE OR REPLACE FUNCTION finance.fn_handoff_rp_latest(p_rp_id int)
RETURNS int
LANGUAGE sql
STABLE
AS $$
    SELECT r.id FROM finance.recurring_payments r
     WHERE r.id IN (SELECT finance.fn_recurring_lineage(p_rp_id))
     ORDER BY (r.valid_to IS NULL OR r.valid_to > r.valid_from) DESC, r.valid_from DESC, r.id DESC
     LIMIT 1;
$$;

CREATE OR REPLACE FUNCTION finance.fn_handoff_ref_state(p_type text, p_id int)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_rp int;
    v   jsonb;
BEGIN
    IF p_type = 'recurring_payment' THEN
        v_rp := finance.fn_handoff_rp_latest(p_id);
        SELECT jsonb_build_object('name', r.name, 'currency', a.currency, 'amount', abs(r.amount),
                                  'day', r.schedule_day_of_month, 'valid_to', finance.fn_recurring_last_valid_day(r.id),
                                  'status', r.status, 'account', a.name, 'to_account', t.name)
          INTO v
          FROM finance.recurring_payments r
          JOIN finance.accounts a ON a.id = r.account_id
          LEFT JOIN finance.accounts t ON t.id = r.target_account_id
         WHERE r.id = v_rp;
    ELSIF p_type = 'savings_goal' THEN
        SELECT jsonb_build_object('name', g.name, 'currency', 'EUR', 'target_amount', g.target_amount,
                                  'target_date', g.target_date, 'status', g.status)
          INTO v FROM finance.savings_goals g WHERE g.id = p_id;
    ELSIF p_type = 'savings_plan' THEN
        SELECT jsonb_build_object('name', sp.name, 'currency', a.currency, 'amount', abs(r.amount),
                                  'day', r.schedule_day_of_month, 'valid_to', finance.fn_recurring_last_valid_day(r.id),
                                  'status', sp.status)
          INTO v
          FROM finance.savings_plans sp
          LEFT JOIN finance.recurring_payments r ON r.id = finance.fn_handoff_rp_latest(sp.recurring_payment_id)
          LEFT JOIN finance.accounts a ON a.id = r.account_id
         WHERE sp.id = p_id;
    ELSIF p_type = 'pension' THEN
        SELECT jsonb_build_object('name', pe.name, 'currency', 'EUR', 'provider', pe.provider,
                                  'guaranteed_monthly_pension', pe.guaranteed_monthly_pension,
                                  'contribution_amount', abs(r.amount), 'status', pe.status)
          INTO v
          FROM finance.pension pe
          LEFT JOIN finance.recurring_payments r ON r.id = finance.fn_handoff_rp_latest(pe.recurring_payment_id)
         WHERE pe.id = p_id;
    END IF;
    RETURN v;
END;
$$;
