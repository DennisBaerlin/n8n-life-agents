-- ============================================================
-- fn_account_flows (READ, STABLE) -- die laufenden und kommenden Dauerauftraege eines Kontos mit ihrem Monatsbetrag
--   Je Kette, die das Konto beruehrt (Quelle oder Uebertrags-Ziel), das massgebliche Glied (fn_recurring_effective),
--   Praedikat wie finance.active_recurring_payments ohne den Start-Filter (status active, valid_to leer oder kuenftig):
--   die Spar-Deckung braucht gerade die erst kommenden Zahlungen. Befristete Zahlungen zaehlen mit.
--   side 'in'  = Eingang ohne Quellkonto (Gehalt, externe Zuwendung) oder Uebertrag AUF das Konto
--   side 'out' = Abgang vom Konto (Sparplan, Uebertrag, Lastschrift)
--   monthly = monthly_equivalent signiert in KONTOwaehrung (Uebertrags-Ziel ueber den Kurs; ohne Kurs NULL).
--   Konsumenten: fn_account_funding (rein/raus je Monat), fn_app_screen_goals („Geld kommt von").
--   RUECKGABE: (rp_id, side, monthly)
--   Tests: tests/db/finance/test_fn_account_funding.sql, tests/db/finance/test_fn_app_screen_goals.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_account_flows(p_account_id int)
RETURNS TABLE(rp_id int, side text, monthly numeric)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_cur CHAR(3);
BEGIN
    SELECT a.currency INTO v_cur FROM finance.accounts a WHERE a.id = p_account_id;
    IF NOT FOUND THEN
        RETURN;
    END IF;
    RETURN QUERY
    WITH h AS (
        SELECT DISTINCT finance.fn_recurring_lineage_head(r.id) AS head
        FROM finance.recurring_payments r
        WHERE r.account_id = p_account_id OR r.target_account_id = p_account_id
    ), g AS (
        SELECT r.id, r.account_id, r.target_account_id, r.monthly_equivalent
        FROM h
        JOIN finance.recurring_payments r ON r.id = finance.fn_recurring_effective(h.head, current_date)
        WHERE r.status = 'active' AND (r.valid_to IS NULL OR r.valid_to > current_date)
          AND (r.account_id = p_account_id OR r.target_account_id = p_account_id)
    )
    SELECT g.id,
           CASE WHEN g.account_id = p_account_id AND g.monthly_equivalent < 0 THEN 'out' ELSE 'in' END,
           CASE WHEN g.account_id = p_account_id THEN g.monthly_equivalent
                WHEN sa.currency = v_cur THEN abs(g.monthly_equivalent)
                ELSE finance.fn_to_eur_unrounded(abs(g.monthly_equivalent), sa.currency)
                     / NULLIF(finance.fn_to_eur_unrounded(1, v_cur), 0) END
    FROM g
    JOIN finance.accounts sa ON sa.id = g.account_id
    ORDER BY g.id;
END;
$$;
