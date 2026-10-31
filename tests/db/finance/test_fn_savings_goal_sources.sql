-- tests/db/finance/test_fn_savings_goal_sources.sql
-- finance.fn_savings_goal_sources(p_goal_id int) — woher kommt die Rate eines bestehenden Ziels (Mini-App UX 2026-10-31).
--   1) Paritaet: zwei Sparplaene, Monatsbetrag wie fn_savings_goal_funding.plan_monthly (vor dem Verknuepfen gerechnet);
--      ein pausierter Plan zaehlt nicht; Plaene nach Monatsbetrag absteigend, mit Depot-Besitzer + Beguenstigtem.
--   2) Raten-Kette: laufend -> transfer; kuenftig startend -> transfer (Pace-Regel 5); beendet -> null.
--   3) Ziel mit Plaenen UND Kette -> beides; nur pausierter Plan -> keine Quelle.
--   4) Plan in Fremdwaehrung ohne Kurs -> plans_fx_gap, Betrag null (nie still zu niedrig).
--   5) unbekanntes Ziel -> {ok:false}; keine Zeile ohne ok.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_chf INT; v_depot INT; v_kid_depot INT; v_rp INT; v_rp2 INT; v_g INT; v_g2 INT;
  v_td date := current_date + 400;
  v_f jsonb; v jsonb;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('sgs_kid', 'Kind Beispiel', 'child');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sgs_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sgs_chf__', 'cash', 'CHF', 'active') RETURNING id INTO v_chf;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__sgs_depot__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__sgs_kid_depot__', 'stocks_depot', 'EUR', 'active', v_giro, 'sgs_kid') RETURNING id INTO v_kid_depot;

  -- ===== 1) Paritaet zu fn_savings_goal_funding =====
  -- Plan A: 4 feste Tage je 40 -> 160 im Monat; Plan B: 40 im Monat; Plan C pausiert
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, schedule_days_of_month, first_payment_date, valid_from)
    VALUES ('__sgs_rp_a__', v_giro, -40, 'month', ARRAY[2, 9, 16, 23]::smallint[], current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, beneficiary_person_id)
    VALUES ('__sgs_plan_a__', v_kid_depot, 'SGS1', 'Welt ETF', v_rp, 'sgs_kid');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__sgs_rp_b__', v_giro, -40, 'month', current_date + 3, current_date + 3) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__sgs_plan_b__', v_depot, 'SGS2', 'Aktie', v_rp);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__sgs_rp_c__', v_giro, -25, 'month', current_date - 30, current_date - 30, 'paused') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, status)
    VALUES ('__sgs_plan_c__', v_depot, 'SGS3', 'Alt ETF', v_rp, 'paused');

  v_f := finance.fn_savings_goal_funding(jsonb_build_object('savings_plan', '__sgs_plan_a__, __sgs_plan_b__',
                                                            'target_amount', 10000), NULL, true, NULL, 0);
  IF (v_f->>'ok')::boolean IS NOT TRUE OR (v_f->>'plan_monthly')::numeric IS NULL THEN
    RAISE EXCEPTION 'FAIL [1a] Vorbedingung fn_savings_goal_funding, got %', v_f; END IF;

  INSERT INTO finance.savings_goals (name, target_amount, target_date)
    VALUES ('__sgs_goal__', 10000, v_td) RETURNING id INTO v_g;
  UPDATE finance.savings_plans SET savings_goal_id = v_g WHERE name IN ('__sgs_plan_a__', '__sgs_plan_b__', '__sgs_plan_c__');

  v := finance.fn_savings_goal_sources(v_g);
  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [1b] ok erwartet, got %', v; END IF;
  IF (v->>'plans_monthly_eur')::numeric IS DISTINCT FROM (v_f->>'plan_monthly')::numeric
     OR (v->>'plans_monthly_eur')::numeric <> 200 THEN
    RAISE EXCEPTION 'FAIL [1c] Monatsbetrag 200 = fn_savings_goal_funding.plan_monthly %, got %', v_f->'plan_monthly', v; END IF;
  IF (v->>'plans_fx_gap')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1d] keine fx-Luecke, got %', v; END IF;
  IF v->'plans' <> jsonb_build_array(
       jsonb_build_object('name', '__sgs_plan_a__', 'depot_owner_person_id', 'sgs_kid', 'beneficiary_person_id', 'sgs_kid'),
       jsonb_build_object('name', '__sgs_plan_b__', 'depot_owner_person_id', NULL, 'beneficiary_person_id', NULL)) THEN
    RAISE EXCEPTION 'FAIL [1e] aktive Plaene nach Monatsbetrag absteigend, pausierter fehlt, got %', v->'plans'; END IF;
  IF jsonb_typeof(v->'transfer') <> 'null' THEN RAISE EXCEPTION 'FAIL [1f] keine Raten-Kette, got %', v; END IF;
  -- monthly_eur zaehlt nur, was heute schon laeuft: Plan A (160, ab heute), nicht Plan B (40, startet in 3 Tagen)
  IF (v->>'monthly_eur')::numeric IS DISTINCT FROM 160 THEN RAISE EXCEPTION 'FAIL [1g] monthly_eur = laufender Plan A 160, got %', v; END IF;
  RAISE NOTICE 'PASS [1] Paritaet zu fn_savings_goal_funding, pausiert zaehlt nicht, Reihenfolge';

  -- ===== 2) Raten-Kette =====
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, schedule_day_of_month,
                                          first_payment_date, valid_from)
    VALUES ('__sgs_rate_now__', v_giro, v_chf, -120, 'month', 1, current_date - 40, current_date - 40) RETURNING id INTO v_rp2;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, recurring_payment_id)
    VALUES ('__sgs_goal_rate__', 5000, v_td, v_rp2) RETURNING id INTO v_g2;
  v := finance.fn_savings_goal_sources(v_g2);
  IF v->'transfer' <> jsonb_build_object('rp_id', v_rp2, 'account_name', '__sgs_giro__', 'account_owner_person_id', NULL)
     OR v->'plans' <> '[]'::jsonb OR jsonb_typeof(v->'plans_monthly_eur') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2a] laufende Rate -> transfer, keine Plaene, got %', v; END IF;
  IF (v->>'monthly_eur')::numeric IS DISTINCT FROM 120 THEN RAISE EXCEPTION 'FAIL [2a2] monthly_eur = laufende Rate 120, got %', v; END IF;
  -- kuenftig startend zaehlt als Quelle (Pace-Regel 5: nicht pausiert), fliesst heute aber noch nicht (monthly_eur 0)
  UPDATE finance.recurring_payments SET first_payment_date = current_date + 10, valid_from = current_date + 10 WHERE id = v_rp2;
  IF (finance.fn_savings_goal_sources(v_g2)->'transfer'->>'rp_id')::int IS DISTINCT FROM v_rp2
     OR (finance.fn_savings_goal_sources(v_g2)->>'monthly_eur')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [2b] kuenftig startende Rate: Quelle, aber monthly_eur 0, got %', finance.fn_savings_goal_sources(v_g2); END IF;
  -- beendet -> keine Quelle
  UPDATE finance.recurring_payments SET first_payment_date = current_date - 90, valid_from = current_date - 90,
                                        valid_to = current_date - 5 WHERE id = v_rp2;
  IF jsonb_typeof(finance.fn_savings_goal_sources(v_g2)->'transfer') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2c] beendete Rate ist keine Quelle, got %', finance.fn_savings_goal_sources(v_g2); END IF;
  -- pausiert -> keine Quelle
  UPDATE finance.recurring_payments SET valid_to = NULL, status = 'paused' WHERE id = v_rp2;
  IF jsonb_typeof(finance.fn_savings_goal_sources(v_g2)->'transfer') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2d] pausierte Rate ist keine Quelle'; END IF;
  RAISE NOTICE 'PASS [2] Raten-Kette laufend / kuenftig / beendet / pausiert';

  -- ===== 3) Plaene UND Kette; nur pausierter Plan =====
  UPDATE finance.recurring_payments SET status = 'active' WHERE id = v_rp2;
  UPDATE finance.savings_goals SET recurring_payment_id = NULL WHERE id = v_g2;   -- eine Kette gehoert einem Ziel (UNIQUE)
  UPDATE finance.savings_goals SET recurring_payment_id = v_rp2 WHERE id = v_g;
  v := finance.fn_savings_goal_sources(v_g);
  IF jsonb_array_length(v->'plans') <> 2 OR (v->'transfer'->>'rp_id')::int IS DISTINCT FROM v_rp2
     OR (v->>'monthly_eur')::numeric IS DISTINCT FROM 280 THEN
    RAISE EXCEPTION 'FAIL [3a] Plaene und Kette zusammen, monthly_eur 160 (Plan A) + 120, got %', v; END IF;
  UPDATE finance.savings_goals SET recurring_payment_id = NULL WHERE id = v_g;
  UPDATE finance.savings_plans SET savings_goal_id = NULL WHERE name IN ('__sgs_plan_a__', '__sgs_plan_b__');
  v := finance.fn_savings_goal_sources(v_g);
  IF v->'plans' <> '[]'::jsonb OR jsonb_typeof(v->'transfer') <> 'null' OR jsonb_typeof(v->'plans_monthly_eur') <> 'null'
     OR (v->>'plans_fx_gap')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [3b] nur pausierter Plan -> keine Quelle, got %', v; END IF;
  RAISE NOTICE 'PASS [3] Quellen-Mix; nur pausiert = keine Quelle';

  -- ===== 4) Fremdwaehrung ohne Kurs =====
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__sgs_rp_chf__', v_chf, -50, 'month', current_date + 3, current_date + 3) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id, savings_goal_id)
    VALUES ('__sgs_plan_chf__', v_depot, 'SGS4', 'Franken ETF', v_rp, v_g);
  UPDATE finance.savings_plans SET savings_goal_id = v_g WHERE name = '__sgs_plan_b__';
  v := finance.fn_savings_goal_sources(v_g);
  IF (v->>'plans_fx_gap')::boolean IS NOT TRUE OR jsonb_typeof(v->'plans_monthly_eur') <> 'null'
     OR jsonb_typeof(v->'monthly_eur') <> 'null' OR jsonb_array_length(v->'plans') <> 2 THEN
    RAISE EXCEPTION 'FAIL [4] CHF ohne Kurs -> fx-Luecke, Betrag null, beide Plaene benannt, got %', v; END IF;
  RAISE NOTICE 'PASS [4] fx-Luecke statt still zu niedrig';

  -- ===== 5) unbekanntes Ziel =====
  IF finance.fn_savings_goal_sources(-1) <> '{"ok":false}'::jsonb OR finance.fn_savings_goal_sources(NULL) <> '{"ok":false}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5] unbekanntes Ziel -> {ok:false}'; END IF;
  RAISE NOTICE 'PASS [5] unbekanntes Ziel';
END $$;
ROLLBACK;
