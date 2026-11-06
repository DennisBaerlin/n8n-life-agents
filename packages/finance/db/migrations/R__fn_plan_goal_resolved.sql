-- ============================================================
-- fn_plan_goal_resolved (READ HELPER, IMMUTABLE, WP2 "Finanzen schlank")
--   Der Finanzplan-Zielblock speichert von Wunsch-Einkommen (target_income_eur_month, real, EUR/Monat), Entnahmerate
--   (withdrawal_rate_pct) und Zielportfolio (target_portfolio_eur, Zahl oder [lo, hi]) nur ZWEI -- der dritte haengt an
--   den beiden (Zielportfolio = Einkommen x 12 / Rate); fn_validate_financial_planning lehnt alle drei zusammen ab
--   (Regel "Keine ableitbaren Spalten"). Diese fn liefert den Block mit dem abgeleiteten dritten Wert -- die EINE Adresse
--   fuer Anzeige (fn_render_plan_facts) und Drift (fn_advisor_review); das LLM rechnet ihn nie.
--     Zielportfolio = round(Einkommen x 12 / Rate x 100)                 (Euro)
--     Einkommen     = round(Zielportfolio(unterer Wert) x Rate / 100 / 12, 2)
--     Rate          = round(Einkommen x 12 / Zielportfolio(unterer Wert) x 100, 2)
--   RUECKGABE: der Block (unveraendert, wenn weniger als zwei Werte da sind) + derived_key (der abgeleitete Schluessel
--   oder NULL). NULL/Nicht-Objekt -> unveraendert.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_plan_goal_resolved(p_goal jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_inc  NUMERIC;
    v_rate NUMERIC;
    v_port NUMERIC;
BEGIN
    IF p_goal IS NULL OR jsonb_typeof(p_goal) <> 'object' THEN
        RETURN p_goal;
    END IF;
    v_inc  := CASE WHEN jsonb_typeof(p_goal->'target_income_eur_month') = 'number' THEN (p_goal->>'target_income_eur_month')::numeric END;
    v_rate := CASE WHEN jsonb_typeof(p_goal->'withdrawal_rate_pct') = 'number' THEN (p_goal->>'withdrawal_rate_pct')::numeric END;
    v_port := CASE jsonb_typeof(p_goal->'target_portfolio_eur')
                  WHEN 'number' THEN (p_goal->>'target_portfolio_eur')::numeric
                  WHEN 'array'  THEN (p_goal->'target_portfolio_eur'->>0)::numeric
              END;
    IF v_inc IS NOT NULL AND v_rate > 0 AND v_port IS NULL THEN
        RETURN p_goal || jsonb_build_object('target_portfolio_eur', ROUND(v_inc * 12 / v_rate * 100),
                                            'derived_key', 'target_portfolio_eur');
    ELSIF v_port > 0 AND v_rate > 0 AND v_inc IS NULL THEN
        RETURN p_goal || jsonb_build_object('target_income_eur_month', ROUND(v_port * v_rate / 100 / 12, 2),
                                            'derived_key', 'target_income_eur_month');
    ELSIF v_inc IS NOT NULL AND v_port > 0 AND v_rate IS NULL THEN
        RETURN p_goal || jsonb_build_object('withdrawal_rate_pct', ROUND(v_inc * 12 / v_port * 100, 2),
                                            'derived_key', 'withdrawal_rate_pct');
    END IF;
    RETURN p_goal || jsonb_build_object('derived_key', NULL);
END;
$$;
