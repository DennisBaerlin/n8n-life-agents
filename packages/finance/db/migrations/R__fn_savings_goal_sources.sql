-- ============================================================
-- fn_savings_goal_sources (READ, STABLE) -- woher kommt die Rate eines BESTEHENDEN Ziels (Mini-App UX 2026-10-31)
--   Die EINE Adresse fuer die Quelle der Rate eines Sparziels, einer Instandhaltungs- oder Notreserve; Konsument:
--   fn_app_screen_goals (Aufklappen „Rate …“). Ein neues Ziel leitet seine Quellen weiter allein fn_savings_goal_funding
--   ab (Write + Import-Karte); beide lesen denselben Monatsbetrag (Paritaets-Test).
--   plans: aktive Sparplaene mit savings_plans.savings_goal_id = Ziel (status active, dasselbe Praedikat wie
--     fn_savings_goal_funding und fn_savings_goal_pace Regel 5), sortiert nach Monatsbetrag absteigend, Name; je Plan
--     {name, depot_owner_person_id, beneficiary_person_id} (die Seite filtert damit ihre Sichtbarkeit).
--     plans_monthly_eur = Summe der Monatsbetraege in EUR wie fn_savings_goal_funding.plan_monthly (heute gueltiges
--     Glied fn_recurring_current, abs(monthly_equivalent), Waehrung seines Kontos; = savings_plan_overview.monthly_amount,
--     die View laeuft aber die Kette ALLER Plaene ab und waere je Ziel zu teuer); fehlt ein Kurs: null + plans_fx_gap
--     (nie still zu niedrig); ohne Plan null.
--   transfer: Raten-Kette savings_goals.recurring_payment_id -> Glied fn_recurring_current(rp, heute), wenn status active
--     und valid_to offen oder kuenftig. Bewusst NICHT exakt active_recurring_payments: ein erst kuenftig startendes Glied
--     zaehlt mit (wie fn_savings_goal_pace Regel 5, „nicht pausiert"; fn_app_order_line nennt dann „ab <Datum>").
--     {rp_id, account_name, account_owner_person_id} | null.
--   RUECKGABE: {ok:true, plans, plans_monthly_eur, plans_fx_gap, transfer} | {ok:false} (unbekanntes Ziel).
--   LANGUAGE plpgsql STABLE, SECURITY INVOKER: nur aus dem DEFINER-Handler fn_app_screen_goals gerufen, kein eigener
--     Rollen-Vertrag (wie fn_depot_cover_state).
--   Tests: tests/db/finance/test_fn_savings_goal_sources.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_savings_goal_sources(p_goal_id int)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_rp       int;
    v_plans    jsonb;
    v_monthly  numeric;
    v_gap      boolean;
    v_transfer jsonb;
BEGIN
    SELECT g.recurring_payment_id INTO v_rp FROM finance.savings_goals g WHERE g.id = p_goal_id;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false);
    END IF;

    -- dieselbe Rechnung wie fn_savings_goal_funding (heute gueltiges Glied, Waehrung seines Kontos), direkt auf den
    -- Tabellen: savings_plan_overview rechnet die Kette ALLER Plaene (MATERIALIZED) und waere je Ziel zu teuer
    SELECT COALESCE(jsonb_agg(jsonb_build_object(
               'name', sp.name,
               'depot_owner_person_id', d.owner_person_id,
               'beneficiary_person_id', sp.beneficiary_person_id)
             ORDER BY finance.fn_to_eur(abs(c.monthly_equivalent), a.currency) DESC NULLS LAST, sp.name, sp.id), '[]'::jsonb),
           round(sum(finance.fn_to_eur(abs(c.monthly_equivalent), a.currency)), 2),
           COALESCE(bool_or(finance.fn_to_eur(abs(c.monthly_equivalent), a.currency) IS NULL), false)
      INTO v_plans, v_monthly, v_gap
      FROM finance.savings_plans sp
      JOIN finance.recurring_payments c ON c.id = finance.fn_recurring_current(sp.recurring_payment_id, current_date)
      JOIN finance.accounts a ON a.id = c.account_id
      JOIN finance.accounts d ON d.id = sp.depot_id
     WHERE sp.savings_goal_id = p_goal_id AND sp.status = 'active';

    IF v_rp IS NOT NULL THEN
        SELECT jsonb_build_object('rp_id', c.id, 'account_name', a.name, 'account_owner_person_id', a.owner_person_id)
          INTO v_transfer
          FROM finance.recurring_payments c
          JOIN finance.accounts a ON a.id = c.account_id
         WHERE c.id = finance.fn_recurring_current(v_rp, current_date)
           AND c.status = 'active'
           AND (c.valid_to IS NULL OR c.valid_to > current_date);
    END IF;

    RETURN jsonb_build_object('ok', true,
        'plans', v_plans,
        'plans_monthly_eur', CASE WHEN NOT v_gap THEN v_monthly END,
        'plans_fx_gap', v_gap,
        'transfer', v_transfer);
END;
$$;
