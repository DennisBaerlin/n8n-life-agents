-- tests/db/finance/test_prop_stop_funders_chain.sql
-- Eigenschafts-Test: "Beitraege eines Sparziels stoppen" (fn_set_savings_goal stop_funders -> fn_stop_savings_goal_funders)
-- gegen die Vorschau, mit und ohne geplante Aenderung am verknuepften Sparplan.
--   T1 nach dem Stoppen zeigt die Vorschau keinen Termin mehr, weder fuer die Ziel-Rate noch fuer ein Glied der
--      Sparplan-Kette (auch nicht fuer das alte Glied, das bis zu einer geplanten Aenderung weiterliefe)
--   T2 das Ziel und der Sparplan fuehren danach keinen Monatswert mehr in der Monatsrechnung
--   T3 den Sparplan wieder aktivieren bringt wieder Termine in die Vorschau
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_giro INT; v_pot INT; v_depot INT; v_goal INT; v_goal_rp INT; v_plan_rp INT; v_planned BOOLEAN; v_n INT := 0; v_cnt INT; v_txt TEXT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_sfc_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_account('{"name":"__prop_sfc_topf__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_pot;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__prop_sfc_depot__','account_type','stocks_depot','currency','EUR',
            'settlement_id',v_giro))->>'account_id')::int INTO v_depot;

  FOREACH v_planned IN ARRAY ARRAY[false, true] LOOP
    BEGIN
      v_res := finance.fn_create_savings_goal(jsonb_build_object('name','__prop_sfc_goal__','goal_type','other','target_amount',6000,
        'target_date',(v_t + interval '24 months')::date,'account_id',v_giro,'reserve_account_id',v_pot,'schedule_day_of_month',1));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T setup goal: %', v_res; END IF;
      v_goal := (v_res->>'goal_id')::int; v_goal_rp := (v_res->>'recurring_payment_id')::int;
      v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_sfc_plan__','depot_name','__prop_sfc_depot__',
        'isin','IE00B3RBWM25','symbol','VWCE','security_name','Testfonds Welt','amount',150,'schedule_interval',1,'schedule_unit','month',
        'first_payment_date',v_t + 5));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T setup plan: %', v_res; END IF;
      v_plan_rp := (v_res->>'recurring_payment_id')::int;
      v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'link_savings_plan_name','__prop_sfc_plan__'));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T setup link: %', v_res; END IF;
      IF v_planned THEN
        v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_sfc_plan__','new_amount',200,'valid_from',v_t + 100));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T setup planned change: %', v_res; END IF;
      END IF;
      IF NOT EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_plan_rp))) THEN
        RAISE EXCEPTION 'FAIL T setup: Sparplan ohne Termine'; END IF;

      v_res := finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'stop_funders',true));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T stop_funders: %', v_res; END IF;
      -- T1
      SELECT string_agg(u.due_date::text || '=' || u.amount, ',' ORDER BY u.due_date) INTO v_txt FROM finance.fn_upcoming_payments(v_t, v_t + 400) u
       WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_plan_rp)) OR u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_goal_rp));
      IF v_txt IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL T1 [geplante Aenderung=%]: nach dem Stoppen stehen noch Termine in der Vorschau: %', v_planned, v_txt; END IF;
      -- T2
      SELECT count(*) INTO v_cnt FROM finance.monthly_cashflow_overview m
       WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_plan_rp)) OR m.id IN (SELECT finance.fn_recurring_lineage(v_goal_rp));
      IF v_cnt <> 0 THEN
        RAISE EXCEPTION 'FAIL T2 [geplante Aenderung=%]: gestoppte Beitraege zaehlen noch in der Monatsrechnung (% Zeilen)', v_planned, v_cnt; END IF;
      -- T3
      v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_sfc_plan__','status','active'));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL T3 [geplante Aenderung=%]: Reaktivieren abgelehnt %', v_planned, v_res; END IF;
      IF NOT EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(v_t, v_t + 400) u
                      WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage((SELECT recurring_payment_id FROM finance.savings_plans WHERE name = '__prop_sfc_plan__')))) THEN
        RAISE EXCEPTION 'FAIL T3 [geplante Aenderung=%]: reaktivierter Sparplan hat keine Termine in der Vorschau (%)', v_planned, v_res - 'card_lines'; END IF;
      v_n := v_n + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE 'PASS prop stop funders chain [% Faelle, T1-T3]', v_n;
END $$;

ROLLBACK;
