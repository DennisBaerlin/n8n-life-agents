-- ============================================================
-- fn_goal_in_derisk_window (READ, STABLE) — "dieses Ziel ist zu kurzfristig fuers Depot"
--   Die eine Adresse der Fenster-Regel des Glide Path (Fenster aus core.config advisor.derisk_window_months,
--   Default 60, mindestens 1): Kalendermonate von heute bis zum Zieldatum <= Fenster -> true, auch ein schon
--   verstrichenes Datum (Restmonate 0, das Geld wird jetzt gebraucht). Ohne Zieldatum (Ruecklagen) oder unbekanntes
--   Ziel -> NULL; der Aufrufer entscheidet (die Ruecklagen-Arten haben eigene Konto-Regeln).
--   Eingabe: p_goal (Ziel-id).
--   Konsumenten: fn_savings_goal_derisk_status (in_window = Zieldatum in der Zukunft und diese Regel; daraus die bewusste
--   Ausnahme fn_goal_depot_risk_fold), Alert standing_order_ending.
--   plpgsql (late-bound): core.fn_config_get gehoert einem anderen Paket.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_goal_in_derisk_window(p_goal int)
RETURNS boolean
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_date date;
    v_win  int;
BEGIN
    SELECT target_date INTO v_date FROM finance.savings_goals WHERE id = p_goal;
    IF v_date IS NULL THEN
        RETURN NULL;
    END IF;
    v_win := GREATEST(COALESCE(NULLIF(core.fn_config_get('core', 'advisor', 'derisk_window_months'), '')::int, 60), 1);
    RETURN GREATEST((EXTRACT(YEAR FROM v_date)::int * 12 + EXTRACT(MONTH FROM v_date)::int)
                    - (EXTRACT(YEAR FROM current_date)::int * 12 + EXTRACT(MONTH FROM current_date)::int), 0) <= v_win;
END;
$$;
