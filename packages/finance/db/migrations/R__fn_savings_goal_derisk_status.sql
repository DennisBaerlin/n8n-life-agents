-- ============================================================
-- fn_savings_goal_derisk_status (READ, STABLE) — Glide Path fuer Sparziele mit Depot-Anteil
--   Umschicht-Hilfe vor dem Zieldatum (Sparziel-Zweckbindung 2026-10-27; Muster Zieldatum-Fonds "Glide Path" bzw.
--   Ablaufmanagement von Rentenvertraegen): je AKTIVEM Ziel mit Depot-Anteil (savings_goal_account_share, Depot-Typen,
--   EUR) darf im Fenster vor dem Zieldatum linear immer weniger im Depot liegen, am Zieldatum 0:
--     months_left       = Kalendermonate von heute bis zum Zieldatum (>= 0)
--     allowed_depot_eur = Ziel * min(months_left / Fenster, 1)
--     excess_eur        = max(Depot-Anteil - erlaubt, 0)   (= Vorschlagsbetrag zum Umschichten)
--     in_window         = Zieldatum in der Zukunft und months_left <= Fenster
--     breach            = in_window und Depot-Anteil > erlaubt + Toleranz (pp des Ziels)
--     active_plan       = ein aktiver Sparplan finanziert das Ziel (kauft weiter ins Depot)
--   Fenster/Toleranz aus core.config advisor.derisk_window_months / derisk_tolerance_pp (COALESCE 60 / 10, Owner-
--   Entscheid 60 Monate). Bewusst eine fn, keine View: core.fn_config_get ist nur fuer die Schreib-/Cron-Rollen
--   freigegeben, eine View braeche fuer finance_ro (Frei-SQL des Buchhalters). Konsument: fn_advisor_review.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_goal_derisk_status()
RETURNS TABLE (goal_id int, name text, target_date date, target_amount numeric, months_left int, window_months int,
               depot_share_eur numeric, allowed_depot_eur numeric, excess_eur numeric, in_window boolean, breach boolean,
               active_plan boolean)
LANGUAGE plpgsql   -- late-bound: core.fn_config_get (anderes Paket) muss beim CREATE noch nicht existieren
STABLE
AS $$
#variable_conflict use_column
BEGIN
    RETURN QUERY
    WITH cfg AS (
        SELECT GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_window_months'), '')::int, 60), 1) AS win,
               COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_tolerance_pp'), '')::numeric, 10)      AS tol
    ), dep AS (
        SELECT s.goal_id, sum(s.share_eur) AS share
        FROM finance.savings_goal_account_share s
        WHERE s.goal_status = 'active' AND s.account_type IN ('stocks_depot', 'crypto_depot')
        GROUP BY s.goal_id
        HAVING sum(s.share_eur) > 0
    ), base AS (
        SELECT g.id, g.name::text AS name, g.target_date, g.target_amount, d.share, c.win, c.tol,
               GREATEST((EXTRACT(YEAR FROM g.target_date)::int * 12 + EXTRACT(MONTH FROM g.target_date)::int)
                        - (EXTRACT(YEAR FROM current_date)::int * 12 + EXTRACT(MONTH FROM current_date)::int), 0) AS months_left
        FROM finance.savings_goals g
        JOIN dep d ON d.goal_id = g.id
        CROSS JOIN cfg c
        WHERE g.status = 'active'
    ), calc AS (
        SELECT b.*, round(b.target_amount * LEAST(b.months_left::numeric / b.win, 1), 2) AS allowed,
               (b.target_date > current_date AND b.months_left <= b.win) AS in_win
        FROM base b
    )
    SELECT c.id, c.name, c.target_date, c.target_amount, c.months_left, c.win,
           round(c.share, 2), c.allowed, round(GREATEST(c.share - c.allowed, 0), 2), c.in_win,
           c.in_win AND c.share > c.allowed + c.target_amount * c.tol / 100,
           EXISTS (SELECT 1 FROM finance.savings_plans sp   -- "laeuft gerade" = active_recurring_payments (nie Status roh)
                   JOIN finance.active_recurring_payments a ON a.id = sp.recurring_payment_id
                   WHERE sp.savings_goal_id = c.id)
    FROM calc c;
END;
$$;
