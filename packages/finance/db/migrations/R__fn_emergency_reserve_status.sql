-- ============================================================
-- fn_emergency_reserve_status (READ, STABLE) -- Notreserve des Haushalts: Ziel, Basis, Deckung, Konten (2026-10-30)
--   Die EINE Rechen-Adresse der Notreserve (Ruecklage kind = emergency_reserve, hoechstens eine aktive). Konsumenten:
--   fn_advisor_review (Alert emergency_reserve), fn_plan_gaps, fn_render_plan_facts, fn_app_screen_goals (Abschnitt
--   „Notreserve“ + Banner), fn_create/fn_set_savings_goal (Karte, Post-State). Das LLM rechnet nichts davon nach.
--   Ziel: target_amount (fest) ODER target_months x Monatsausgaben; Monatsausgaben = fn_liquidity_snapshot
--   (feste Zahlungen + Kreditraten ohne Sparraten + geschaetzter Alltag) — gespeichert ist nur die Einstellung, der
--   Betrag wird zur Laufzeit abgeleitet (Ausgaben aendern sich; DB-Gesetz „keine ableitbaren Spalten“).
--   Deckung: finance.fn_emergency_reserve_covered (je Geld-Konto, nach den anderen Zielen, hoechstens der Saldo).
--   state: neutral = kein Ziel bestimmbar (Monate ohne Ausgaben-Daten) oder Kurs fehlt; ok = gedeckt; warn = darunter.
--   RUECKGABE jsonb: {exists:false} | {exists:true, goal_id, name, target_kind ('amount'|'months'), months, target_eur,
--   basis:{monthly_eur, fixed_eur, everyday_eur, everyday_accounts, everyday_provisional}, covered_eur,
--   accounts:[{name, eur}], gap_eur, state, has_fx_gap}
--   Tests: tests/db/finance/test_fn_emergency_reserve_status.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_emergency_reserve_status()
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_g      finance.savings_goals%ROWTYPE;
    v_snap   JSONB;
    v_month  NUMERIC;
    v_target NUMERIC;
    v_cov    NUMERIC;
    v_accts  JSONB;
    v_gap    BOOLEAN;
    v_state  TEXT;
BEGIN
    SELECT * INTO v_g FROM finance.savings_goals WHERE kind = 'emergency_reserve' AND status = 'active'
     ORDER BY id LIMIT 1;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('exists', false);
    END IF;
    v_snap  := finance.fn_liquidity_snapshot();
    v_month := COALESCE((v_snap->>'monthly_expenses_eur')::numeric, 0);
    v_target := CASE WHEN v_g.target_amount IS NOT NULL THEN v_g.target_amount
                     WHEN v_month > 0 THEN round(v_g.target_months * v_month, 2) END;

    SELECT COALESCE(sum(c.covered_eur), 0),
           COALESCE(jsonb_agg(jsonb_build_object('name', c.account_name, 'eur', c.covered_eur)
                              ORDER BY c.covered_eur DESC, c.account_name) FILTER (WHERE c.covered_eur > 0), '[]'::jsonb),
           COALESCE(bool_or(c.fx_gap), false)
      INTO v_cov, v_accts, v_gap
      FROM finance.fn_emergency_reserve_covered() c;

    v_state := CASE WHEN v_target IS NULL OR v_gap THEN 'neutral'
                    WHEN v_cov >= v_target THEN 'ok'
                    ELSE 'warn' END;

    RETURN jsonb_build_object('exists', true,
        'goal_id', v_g.id, 'name', v_g.name,
        'target_kind', CASE WHEN v_g.target_amount IS NOT NULL THEN 'amount' ELSE 'months' END,
        'months', v_g.target_months,
        'target_eur', v_target,
        'basis', jsonb_build_object(
            'monthly_eur', v_month,
            'fixed_eur', (v_snap->>'fixed_expenses_eur')::numeric,
            'everyday_eur', (v_snap->>'everyday_eur')::numeric,
            'everyday_accounts', (v_snap->>'everyday_accounts')::int,
            'everyday_provisional', (v_snap->>'everyday_provisional')::boolean),
        'covered_eur', v_cov,
        'accounts', v_accts,
        'gap_eur', CASE WHEN v_target IS NOT NULL THEN GREATEST(v_target - v_cov, 0) END,
        'state', v_state,
        'has_fx_gap', v_gap OR COALESCE((v_snap->>'has_fx_gap')::boolean, false));
END;
$$;
