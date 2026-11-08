-- tests/db/finance/test_fn_plan_goal_resolved.sql
-- WP2 "Finanzen schlank": vom Finanzplan-Ziel (Einkommen, Entnahmerate, Zielportfolio) werden nur ZWEI gespeichert; der
-- Validator lehnt alle drei ab, fn_plan_goal_resolved leitet den dritten ab (Anzeige + Drift; nie gespeichert).
BEGIN;

DO $$
DECLARE v jsonb;
BEGIN
  -- Einkommen + Rate -> Zielportfolio 2.500 x 12 / 4 % = 750.000
  v := finance.fn_plan_goal_resolved('{"target_income_eur_month":2500,"withdrawal_rate_pct":4}');
  IF (v->>'target_portfolio_eur')::numeric IS DISTINCT FROM 750000 OR v->>'derived_key' IS DISTINCT FROM 'target_portfolio_eur' THEN
    RAISE EXCEPTION 'FAIL [portfolio]: %', v; END IF;
  -- Zielportfolio (Spanne: unterer Wert) + Rate -> Einkommen 750.000 x 4 % / 12 = 2.500
  v := finance.fn_plan_goal_resolved('{"target_portfolio_eur":[750000,850000],"withdrawal_rate_pct":4}');
  IF (v->>'target_income_eur_month')::numeric IS DISTINCT FROM 2500.00 OR v->'target_portfolio_eur' <> '[750000,850000]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [income]: %', v; END IF;
  -- Einkommen + Zielportfolio -> Rate 2.500 x 12 / 900.000 = 3,33 %
  v := finance.fn_plan_goal_resolved('{"target_income_eur_month":2500,"target_portfolio_eur":900000}');
  IF (v->>'withdrawal_rate_pct')::numeric IS DISTINCT FROM 3.33 THEN RAISE EXCEPTION 'FAIL [rate]: %', v; END IF;
  -- weniger als zwei Werte -> nichts abgeleitet
  v := finance.fn_plan_goal_resolved('{"withdrawal_rate_pct":4}');
  IF v ? 'target_portfolio_eur' OR v->>'derived_key' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [einer]: %', v; END IF;
  IF finance.fn_plan_goal_resolved(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [null]'; END IF;
  -- Nicht-Objekt bleibt unveraendert
  IF finance.fn_plan_goal_resolved('[1,2]') IS DISTINCT FROM '[1,2]'::jsonb THEN RAISE EXCEPTION 'FAIL [array]'; END IF;
  -- Rate oder Portfolio 0 leiten nichts ab (keine Division durch 0, kein Einkommen 0)
  v := finance.fn_plan_goal_resolved('{"target_income_eur_month":2500,"withdrawal_rate_pct":0}');
  IF v->>'derived_key' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Rate 0 -> Portfolio]: %', v; END IF;
  v := finance.fn_plan_goal_resolved('{"target_portfolio_eur":0,"withdrawal_rate_pct":4}');
  IF v->>'derived_key' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Portfolio 0 -> Einkommen]: %', v; END IF;
  v := finance.fn_plan_goal_resolved('{"target_portfolio_eur":700000,"withdrawal_rate_pct":0}');
  IF v->>'derived_key' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [Rate 0 -> Einkommen]: %', v; END IF;
  -- Einkommen auf Cent: 100.000 x 3,5 % / 12 = 291,67
  v := finance.fn_plan_goal_resolved('{"target_portfolio_eur":100000,"withdrawal_rate_pct":3.5}');
  IF (v->>'target_income_eur_month')::numeric IS DISTINCT FROM 291.67 THEN RAISE EXCEPTION 'FAIL [Einkommen Cent]: %', v; END IF;

  -- Validator: alle drei -> abgelehnt, zwei -> gueltig
  IF finance.fn_validate_financial_planning(
       '{"goal":{"target_income_eur_month":2500,"withdrawal_rate_pct":4,"target_portfolio_eur":750000}}') IS NULL THEN
    RAISE EXCEPTION 'FAIL [validator drei]: alle drei akzeptiert'; END IF;
  IF finance.fn_validate_financial_planning('{"goal":{"target_income_eur_month":2500,"withdrawal_rate_pct":4}}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [validator zwei]: zwei abgelehnt'; END IF;
  RAISE NOTICE 'PASS fn_plan_goal_resolved (Portfolio/Einkommen/Rate abgeleitet, Spanne bleibt, Validator 3 von 3 abgelehnt)';
END $$;

ROLLBACK;
