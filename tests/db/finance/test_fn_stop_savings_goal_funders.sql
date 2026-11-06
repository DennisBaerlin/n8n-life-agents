-- tests/db/finance/test_fn_stop_savings_goal_funders.sql
-- WS-B Stufe 3 (Phase S): fn_stop_savings_goal_funders — Lebenszyklus "ERREICHT" (Ziel voll, aber NICHT
--   ausgegeben). Stoppt ALLE Beitraege eines Ziels (Cash-Rate + 0..N verknuepfte Sparplaene mit ihren rps),
--   laesst Ziel + Reserve UNBERUEHRT (nie automatisch; nur auf Owner-Wunsch ueber den set-Pfad).
--   (1) Cash-rp paused + valid_to=heute.
--   (2) ALLE verknuepften Sparplaene paused + ihre rps paused + valid_to=heute (Menge der Quellen, nicht "die" rp).
--   (3) Ziel-Status bleibt 'active'; das Reserve-Journal bleibt unveraendert (erreicht != ausgegeben).
--   (4) Nicht-verknuepfter Sparplan (anderes/kein Ziel) bleibt aktiv.
--   (5) Rueckgabe-Zaehler (paused_cash_rate, paused_plan_count).
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res     JSONB;
  v_fund    INT;          -- Verrechnungs-/Funding-Konto
  v_depot   INT;          -- Depot (Marktwert-Deckung)
  v_goal    INT; v_rp_cash INT;
  v_rp_p1   INT; v_rp_p2 INT; v_plan1 INT; v_plan2 INT;
  v_rp_other INT; v_plan_other INT;
  v_status  TEXT; v_valid_to DATE; v_journal_sum NUMERIC;
BEGIN
  -- Konten
  SELECT finance.fn_create_account('{"name":"__test_ssf_fund__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_fund := (v_res->>'account_id')::int;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__test_ssf_depot__','stocks_depot','EUR','active', v_fund) RETURNING id INTO v_depot;

  -- Ziel mit Cash-Rate (fn legt die recurring_payment an)
  SELECT finance.fn_create_savings_goal(jsonb_build_object(
    'name','__test_ssf_goal__','target_amount',12000,'target_date',(CURRENT_DATE + 365)::text,
    'monthly_savings_rate',200,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_fund,'first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_goal := (v_res->>'goal_id')::int; v_rp_cash := (v_res->>'recurring_payment_id')::int;

  -- Zwei verknuepfte Sparplaene (je eigene aktive recurring_payment), savings_goal_id = unser Ziel
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__test_ssf_rp1__', v_fund, -50, 'week', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp_p1;
  INSERT INTO finance.savings_plans (name, depot_id, isin, symbol, security_name, recurring_payment_id, savings_goal_id, status)
  VALUES ('__test_ssf_plan1__', v_depot, 'IE00BK5BQT80','VWCE','World ETF', v_rp_p1, v_goal, 'active') RETURNING id INTO v_plan1;

  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__test_ssf_rp2__', v_fund, -25, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp_p2;
  INSERT INTO finance.savings_plans (name, depot_id, isin, symbol, security_name, recurring_payment_id, savings_goal_id, status)
  VALUES ('__test_ssf_plan2__', v_depot, 'IE00B4L5Y983','IWDA','World ETF 2', v_rp_p2, v_goal, 'active') RETURNING id INTO v_plan2;

  -- Nicht-verknuepfter Sparplan (kein Ziel) -> muss aktiv bleiben
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
  VALUES ('__test_ssf_rp_other__', v_fund, -10, 'month', CURRENT_DATE, CURRENT_DATE) RETURNING id INTO v_rp_other;
  INSERT INTO finance.savings_plans (name, depot_id, isin, symbol, security_name, recurring_payment_id, savings_goal_id, status)
  VALUES ('__test_ssf_plan_other__', v_depot, 'XX0000000099','OTH','Other', v_rp_other, NULL, 'active') RETURNING id INTO v_plan_other;

  -- Depot-Reserve-Journal (muss UNVERAENDERT bleiben)
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
  VALUES (v_goal, v_depot, 1500, 'manual');

  -- ===== AKTION =====
  SELECT finance.fn_stop_savings_goal_funders(jsonb_build_object('goal_id', v_goal)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL stop_funders: kein ok:true (%)', v_res; END IF;

  -- (1) Cash-rp paused + valid_to=heute
  SELECT status::text, valid_to INTO v_status, v_valid_to FROM finance.recurring_payments WHERE id = v_rp_cash;
  IF v_status IS DISTINCT FROM 'paused' OR v_valid_to IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL stop_funders [1]: Cash-rp nicht paused/valid_to (status=%, valid_to=%)', v_status, v_valid_to; END IF;
  RAISE NOTICE 'PASS stop_funders [1: Cash-Rate paused + valid_to=heute]';

  -- (2) beide verknuepften Sparplaene + ihre rps paused
  PERFORM 1 FROM finance.recurring_payments WHERE id IN (v_rp_p1, v_rp_p2) AND (status <> 'paused' OR valid_to IS DISTINCT FROM CURRENT_DATE);
  IF FOUND THEN RAISE EXCEPTION 'FAIL stop_funders [2]: verknuepfte Sparplan-rp nicht paused/valid_to'; END IF;
  PERFORM 1 FROM finance.savings_plans WHERE id IN (v_plan1, v_plan2) AND status <> 'paused';
  IF FOUND THEN RAISE EXCEPTION 'FAIL stop_funders [2]: verknuepfter Sparplan nicht paused'; END IF;
  RAISE NOTICE 'PASS stop_funders [2: alle verknuepften Sparplaene + deren rps paused (Menge der Quellen)]';

  -- (3) Ziel-Status bleibt active; Journal unveraendert
  SELECT status::text INTO v_status FROM finance.savings_goals WHERE id = v_goal;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'FAIL stop_funders [3]: Ziel-Status veraendert (%)', v_status; END IF;
  SELECT COALESCE(sum(delta_native),0) INTO v_journal_sum FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_journal_sum IS DISTINCT FROM 1500 THEN RAISE EXCEPTION 'FAIL stop_funders [3]: Reserve-Journal veraendert (Summe=%)', v_journal_sum; END IF;
  RAISE NOTICE 'PASS stop_funders [3: Ziel bleibt active, Reserve unberuehrt (erreicht != ausgegeben)]';

  -- (4) nicht-verknuepfter Sparplan bleibt aktiv
  SELECT status::text INTO v_status FROM finance.savings_plans WHERE id = v_plan_other;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'FAIL stop_funders [4]: fremder Sparplan paused (%)', v_status; END IF;
  SELECT status::text INTO v_status FROM finance.recurring_payments WHERE id = v_rp_other;
  IF v_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'FAIL stop_funders [4]: fremde rp paused (%)', v_status; END IF;
  RAISE NOTICE 'PASS stop_funders [4: nicht-verknuepfter Sparplan unberuehrt]';

  -- (5) Rueckgabe-Zaehler
  IF (v_res->>'paused_plan_count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL stop_funders [5]: paused_plan_count erwartet 2, got %', v_res->>'paused_plan_count'; END IF;
  IF (v_res->>'paused_cash_rate')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL stop_funders [5]: paused_cash_rate erwartet true, got %', v_res->>'paused_cash_rate'; END IF;
  RAISE NOTICE 'PASS stop_funders [5: Post-State-Zaehler (paused_cash_rate, paused_plan_count)]';
END $$;

ROLLBACK;
