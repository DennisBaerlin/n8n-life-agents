-- tests/db/finance/test_recalc2_coverage.sql
-- Zweitrechnung Deckung: Depot-Deckung (fn_depot_cover_state), Spar-Deckung eines Kontos (fn_account_funding),
-- Plan-Luecken (fn_plan_gap_count). Erwartungen von Hand hergeleitet. Werte erfunden.
-- Fachregeln (aus dem fn-Kopf als Spezifikation, Rechnung selbst):
--   * Depot: Fehlbetrag = Reserve - Marktwert; Kursdelle, wenn Fehlbetrag < 10 % der Reserve, sonst Luecke.
--     (1) Reserve 6.000 + 4.000 (zwei Ziele) = 10.000; Marktwert 9.001 -> Fehlbetrag 999 < 1.000 -> dip;
--         9.000 -> 1.000 = 10 % -> short (Grenze ist Luecke); 10.000 -> ok, gap 0.
--   * Konto-Deckung: Tagesreihe Saldo + geplante Ab-/Zugaenge; Schwelle = Ziel-Geld auf dem Konto; erster Tag darunter =
--     runs_out_on; innerhalb von 3 Monaten alert, innerhalb des Horizonts (24 Monate) warn.
--     Konto 1.000 (davon 650 Ziel-Geld), Sparplan -300 ab morgen monatlich, Zufluss +200 ab uebermorgen monatlich:
--       nach der k-ten Sparplan-Abbuchung (k = 0, 1, ...) 700 - 100k, nach dem Zufluss 900 - 100k.
--     (2) Schwelle 650: k = 1 -> 600 < 650 -> runs_out_on = morgen + 1 Monat, alert.
--     (3) Ohne Ziel-Geld (Schwelle 0): 700 - 100k < 0 erst bei k = 8 (k = 7 -> 0 ist nicht darunter)
--         -> runs_out_on = morgen + 8 Monate, warn. Monatswerte: rein 200,00, raus 300,00.
--   * Plan-Luecken = nie bestaetigte Sektionen + bestaetigte ohne Pflicht-Block + nur im Entwurf.
--     (4) Aktiv bestaetigt: household_basics, risk_profile, wealth_building, goals_triggers, emergency_reserve; eine
--         fruehere Version: risk_protection; Entwurf: debts_loans. Bloecke: risk_profile + target_allocation vorhanden,
--         glidepath und goal fehlen, keine Notreserve angelegt.
--         offen: retirement_pension, crossborder (2); nur Entwurf: debts_loans (1); fehlende Bloecke: Notreserve,
--         glidepath, goal (3) -> 6.
BEGIN;

UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.savings_goals SET status = 'completed' WHERE status = 'active';

DO $$
DECLARE
  v_settle int; v_dep int; v_g1 int; v_g2 int; v_acc int; v_src int; v_rp int; v_goal int; r jsonb; v_tm date := current_date + 1;
BEGIN
  -- (1) Depot-Deckung
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cov_settle__', 'cash', 'EUR', 'active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__r2cov_dep__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency) VALUES (v_dep, 'R2CV', 'Welt', 100, 80, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('R2CV', 90.01, 'EUR', current_date);
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__r2cov_g1__', 8000, current_date + 400) RETURNING id INTO v_g1;
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__r2cov_g2__', 8000, current_date + 400) RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (v_g1, v_dep, 6000, 'manual'), (v_g2, v_dep, 4000, 'manual');
  r := finance.fn_depot_cover_state(v_dep);
  IF r->>'state' <> 'dip' OR (r->>'gap')::numeric IS DISTINCT FROM 999.00 OR (r->>'reserved')::numeric IS DISTINCT FROM 10000 THEN
    RAISE EXCEPTION 'FAIL [1a] 9.001 gegen 10.000 -> dip 999, got %', r; END IF;
  UPDATE finance.market_prices SET price = 90.00 WHERE symbol = 'R2CV';
  r := finance.fn_depot_cover_state(v_dep);
  IF r->>'state' <> 'short' OR (r->>'gap')::numeric IS DISTINCT FROM 1000.00 THEN
    RAISE EXCEPTION 'FAIL [1b] genau 10 %% -> short, got %', r; END IF;
  UPDATE finance.market_prices SET price = 100.00 WHERE symbol = 'R2CV';
  r := finance.fn_depot_cover_state(v_dep);
  IF r->>'state' <> 'ok' OR (r->>'gap')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [1c] gedeckt -> ok, got %', r; END IF;
  RAISE NOTICE 'PASS [1] Depot-Deckung: 999 Delle, 1.000 = 10 %% Luecke, gedeckt ok';

  -- (2)/(3) Konto-Deckung
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cov_acc__', 'cash', 'EUR', 'active') RETURNING id INTO v_acc;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2cov_src__', 'cash', 'EUR', 'active') RETURNING id INTO v_src;
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__r2cov_ziel__', 5000, current_date + 900) RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acc, 350, current_date - 3, 'other');
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_acc, 650, current_date - 3, 'transfer', v_goal, gen_random_uuid());
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2cov_plan__', v_acc, -300, 'month', v_tm, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id) VALUES ('__r2cov_sp__', v_dep, 'R2CV', 'Welt', v_rp);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2cov_zufluss__', v_src, v_acc, -200, 'month', current_date + 2, current_date);
  r := finance.fn_account_funding(v_acc);
  IF (r->>'runs_out_on')::date IS DISTINCT FROM (v_tm + interval '1 month')::date OR r->>'state' <> 'alert'
     OR (r->>'reserved')::numeric IS DISTINCT FROM 650.00 OR r->>'everyday' <> 'none' THEN
    RAISE EXCEPTION 'FAIL [2] Schwelle 650: erwartet % / alert, got %', (v_tm + interval '1 month')::date, r; END IF;
  RAISE NOTICE 'PASS [2] Konto-Deckung mit Ziel-Geld 650 -> nach der 2. Abbuchung darunter, alert';
  DELETE FROM finance.transactions WHERE account_id = v_acc AND savings_goal_id = v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_acc, 650, current_date - 3, 'other');
  r := finance.fn_account_funding(v_acc);
  IF (r->>'runs_out_on')::date IS DISTINCT FROM (v_tm + interval '8 months')::date OR r->>'state' <> 'warn'
     OR abs((r->>'monthly_in')::numeric) IS DISTINCT FROM 200.00 OR abs((r->>'monthly_out')::numeric) IS DISTINCT FROM 300.00 THEN
    RAISE EXCEPTION 'FAIL [3] ohne Ziel-Geld: erwartet % / warn / 200 / 300, got %', (v_tm + interval '8 months')::date, r; END IF;
  RAISE NOTICE 'PASS [3] Konto-Deckung ohne Ziel-Geld: 0 ist nicht darunter, erst die 9. Abbuchung, warn';

  -- (4) Plan-Luecken
  DELETE FROM agent.advisor_plans WHERE domain = 'finance' AND person_id IS NULL;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md) VALUES
    ('finance', NULL, 'Plan', 'superseded', 1, '{"risk_protection":{"content":"x"}}', 'p'),
    ('finance', NULL, 'Plan', 'active', 2, '{"household_basics":{"content":"x"},"risk_profile":{"content":"x"},
       "wealth_building":{"content":"x"},"goals_triggers":{"content":"x"},"emergency_reserve":{"content":"x"}}', 'p'),
    ('finance', NULL, 'Entwurf', 'draft', 3, '{"debts_loans":{"content":"x"}}', NULL);
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'test fixture', NULL, 'lazy', E'## Plan', '{}'::jsonb) ON CONFLICT (name) DO NOTHING;
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'risk_profile', jsonb_build_object('tolerance', 'balanced'),
      'target_allocation', jsonb_build_object('blocks', '[]'::jsonb))) WHERE name = 'financial_planning';
  IF finance.fn_plan_gap_count('finance', NULL) IS DISTINCT FROM 6 THEN
    RAISE EXCEPTION 'FAIL [4] Plan-Luecken: erwartet 6, got % (%)', finance.fn_plan_gap_count('finance', NULL),
      finance.fn_plan_gaps((SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'financial_planning')); END IF;
  RAISE NOTICE 'PASS [4] Plan-Luecken 2 offen + 1 Entwurf + 3 fehlende Bloecke = 6';
END $$;

ROLLBACK;
