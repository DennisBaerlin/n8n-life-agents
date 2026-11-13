-- tests/db/finance/test_recalc2_advisor.sql
-- Zweitrechnung Berater (finance.fn_advisor_review): Alert-Schwellen an ihren Grenzen. Erwartungen von Hand
-- hergeleitet. Werte erfunden.
-- Fachregeln:
--   * Zielmix (Rebalancing mit Toleranzband, z. B. https://www.bogleheads.org/wiki/Rebalancing "5/25-Regel" als absolute
--     Prozentpunkte): Soll eines handelbaren Blocks = Plan-Anteil / Summe der handelbaren Plan-Anteile x 100 (Festgeld
--     ist nicht handelbar), Ist = Wert / Summe der handelbaren Werte mit Plan-Block x 100. Alarm, wenn |Ist - Soll| >
--     Toleranz (Default 5 pp) bzw. Ist ausserhalb eines Korridors (Korridor-Grenzen mit demselben Faktor umgerechnet,
--     Grenze selbst gilt als drin).
--   * Monats-Puffer: frei = Einnahmen - Pflichtausgaben; Defizit-Alarm bei frei < 0, Puffer-Hinweis bei
--     frei < 10 % der Einnahmen (Grenze selbst kein Hinweis); Spar-Engpass, wenn frei >= 0, gespart wird und das Konto
--     trotzdem schrumpft (frei - Sparen < 0).
--   Plan: Welt 50, Anleihen 20, Cash 10, Festgeld 20 -> handelbar 80: Soll Welt 62,50 / Anleihen 25,00 / Cash 12,50.
--   Bestand: Welt 55.000, Anleihen 15.000, Giro 10.000, Festgeld 20.000 -> handelbar 80.000.
--   (1) Ist Welt 68,75 (+6,25 > 5 -> Alarm), Anleihen 18,75 (-6,25 -> Alarm), Cash 12,50 (0 -> kein Alarm).
--   (2) Anleihen-Korridor 15..25 Plan-% -> 18,75..31,25: Ist 18,75 liegt auf der Grenze -> kein Alarm.
--   (3) Toleranz 6,25: |+6,25| ist nicht groesser -> kein Alarm fuer Welt.
--   (4) Einnahmen 3.000: Miete 2.650 -> frei 350 >= 300 kein Hinweis; Miete 2.700 -> frei 300 = Grenze kein Hinweis;
--       Miete 2.700,01 -> frei 299,99 -> Puffer-Hinweis (Ziel 300,00, Abstand 0,01); Miete 3.100 -> Defizit -100,00.
--   (5) Miete 2.700 + Sparplan 400 -> frei 300, Kontoveraenderung -100 -> Spar-Engpass 100,00.
BEGIN;

UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.account_balances SET balance = 0;
UPDATE finance.depot_holdings SET shares = 0;
UPDATE finance.real_estate SET current_value = NULL;
UPDATE finance.pension SET current_value = NULL;
DELETE FROM finance.savings_goal_reserve_entries;
UPDATE finance.savings_goals SET status = 'completed';

DO $$
DECLARE
  r jsonb; v_giro int; v_depot int; v_fd int; v_rent int; v_rp int; a jsonb;
  v_blocks jsonb := jsonb_build_array(
      jsonb_build_object('key','world','name','Welt','target_pct',50),
      jsonb_build_object('key','bonds','name','Anleihen','target_pct',20),
      jsonb_build_object('key','cash','name','Cash','target_pct',10),
      jsonb_build_object('key','fixed_deposit','name','Festgeld','target_pct',20));
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'test fixture', NULL, 'lazy', E'## Plan', '{}'::jsonb)
  ON CONFLICT (name) DO NOTHING;
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'target_allocation', jsonb_build_object('rebalance_drift_pp', 5, 'blocks', v_blocks),
      '_meta', jsonb_build_object('last_confirmed_at', to_char(current_date, 'YYYY-MM-DD'))))
   WHERE name = 'financial_planning';

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2adv_giro__','cash','EUR','active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__r2adv_depot__','stocks_depot','EUR','active', v_giro) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__r2adv_fd__','fixed_deposit','EUR','active', current_date + 500) RETURNING id INTO v_fd;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class) VALUES
    (v_depot, 'R2V00000001', 'R2VW', 'Welt', 550, 100, 'EUR', 'world'),
    (v_depot, 'R2V00000002', 'R2VB', 'Anleihen', 150, 100, 'EUR', 'bonds');
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_giro;
  UPDATE finance.account_balances SET balance = 20000 WHERE account_id = v_fd;

  -- (1)
  r := finance.fn_advisor_review('finance');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rebalanceable_drift') b WHERE b->>'key' = 'world'
                   AND (b->>'target_pct')::numeric = 62.50 AND (b->>'actual_pct')::numeric = 68.75 AND (b->>'drift')::numeric = 6.25)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rebalanceable_drift') b WHERE b->>'key' = 'bonds'
                   AND (b->>'target_pct')::numeric = 25.00 AND (b->>'actual_pct')::numeric = 18.75 AND (b->>'drift')::numeric = -6.25)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'rebalanceable_drift') b WHERE b->>'key' = 'cash'
                   AND (b->>'actual_pct')::numeric = 12.50 AND NOT (b->>'breach')::boolean) THEN
    RAISE EXCEPTION 'FAIL [1] Zielmix-Rechnung: %', r->'rebalanceable_drift'; END IF;
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'alloc:world')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'alloc:bonds')
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'alloc:cash') THEN
    RAISE EXCEPTION 'FAIL [1b] Zielmix-Alarme: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [1] Zielmix: Soll 62,5/25/12,5, Ist 68,75/18,75/12,5, Alarm bei 6,25 pp';

  -- (2) Korridor-Grenze
  v_blocks := jsonb_set(v_blocks, '{1,corridor}', '[15,25]');
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_allocation,blocks}', v_blocks) WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'alloc:bonds') THEN
    RAISE EXCEPTION 'FAIL [2] Korridor-Grenze 18,75 gilt als drin: %', r->'rebalanceable_drift'; END IF;
  RAISE NOTICE 'PASS [2] Korridor 15..25 -> 18,75..31,25, Grenze kein Alarm';

  -- (3) Toleranz-Grenze
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_allocation,rebalance_drift_pp}', '6.25') WHERE name = 'financial_planning';
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'metric_key' = 'alloc:world') THEN
    RAISE EXCEPTION 'FAIL [3] Toleranz 6,25: Drift 6,25 ist nicht groesser'; END IF;
  RAISE NOTICE 'PASS [3] Toleranz-Grenze 6,25 kein Alarm';
  UPDATE agent.core_contexts SET metadata = metadata - 'facts' WHERE name = 'financial_planning';

  -- (4) Monats-Puffer
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2adv_gehalt__', v_giro, 3000, 'month', current_date, current_date);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2adv_miete__', v_giro, -2650, 'month', current_date, current_date) RETURNING id INTO v_rent;
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [4a] frei 350 -> kein Hinweis: %', r->'alerts'; END IF;
  UPDATE finance.recurring_payments SET amount = -2700 WHERE id = v_rent;
  r := finance.fn_advisor_review('finance');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [4b] frei 300 = Grenze -> kein Hinweis: %', r->'alerts'; END IF;
  UPDATE finance.recurring_payments SET amount = -2700.01 WHERE id = v_rent;
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->>'value')::numeric IS DISTINCT FROM 299.99 OR (a->>'target')::numeric IS DISTINCT FROM 300.00
     OR (a->>'drift')::numeric IS DISTINCT FROM 0.01 THEN
    RAISE EXCEPTION 'FAIL [4c] Puffer-Hinweis 299,99 / 300 / 0,01: %', a; END IF;
  UPDATE finance.recurring_payments SET amount = -3100 WHERE id = v_rent;
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->>'value')::numeric IS DISTINCT FROM -100.00 OR (a->>'target')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [4d] Defizit -100: %', a; END IF;
  RAISE NOTICE 'PASS [4] Puffer 10 %%: 350 / 300 still, 299,99 Hinweis, -100 Defizit';

  -- (5) Spar-Engpass
  UPDATE finance.recurring_payments SET amount = -2700 WHERE id = v_rent;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2adv_etf__', v_giro, -400, 'month', current_date, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__r2adv_plan__', v_depot, 'R2VW', 'Welt', v_rp);
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'savings_squeeze';
  IF (a->>'value')::numeric IS DISTINCT FROM -100.00 OR (a->>'drift')::numeric IS DISTINCT FROM 100.00
     OR EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [5] Spar-Engpass 100: %', r->'alerts'; END IF;
  RAISE NOTICE 'PASS [5] Spar-Engpass: frei 300, Sparplan 400 -> Konto -100';

  -- (6) Latch (Edge-Trigger, Prometheus/Alertmanager-Muster): erster Bruch sendet, derselbe Bruch bleibt still,
  --     zurueck im Band re-armt, erneuter Bruch sendet wieder.
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp;
  DELETE FROM core.notification_state WHERE source = 'advisor:finance';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance') ON CONFLICT (domain) DO NOTHING;
  UPDATE finance.recurring_payments SET amount = -3100 WHERE id = v_rent;
  r := core.fn_advisor_review_evaluate('finance');
  IF (r->>'send')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage') THEN
    RAISE EXCEPTION 'FAIL [6a] erster Bruch sendet: %', r; END IF;
  r := core.fn_advisor_review_evaluate('finance');
  IF (r->>'send')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6b] derselbe Bruch still: %', r; END IF;
  UPDATE finance.recurring_payments SET amount = -2600 WHERE id = v_rent;
  r := core.fn_advisor_review_evaluate('finance');
  IF (r->>'send')::boolean IS DISTINCT FROM false
     OR EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor:finance' AND key = 'cashflow_coverage' AND state = 'fired') THEN
    RAISE EXCEPTION 'FAIL [6c] im Band -> still und re-armt: %', r; END IF;
  UPDATE finance.recurring_payments SET amount = -3100 WHERE id = v_rent;
  r := core.fn_advisor_review_evaluate('finance');
  IF (r->>'send')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [6d] erneuter Bruch sendet: %', r; END IF;
  RAISE NOTICE 'PASS [6] Latch: senden, still, re-armen, wieder senden';
END $$;

ROLLBACK;

-- Puffer-Hinweis knapp unter dem Ziel: abgerundet, nie "10,0 %" bei Ziel 10 %. Einnahmen 3.000, frei 299,99 -> 9,9.
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.account_balances SET balance = 0;
DO $$
DECLARE v_giro int; r jsonb; a jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f2_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__r2f2_gehalt__', v_giro, 3000, 'month', current_date, current_date),
    ('__r2f2_miete__', v_giro, -2700.01, 'month', current_date, current_date);
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->'msg'->0->'params'->'pct'->>'value')::numeric IS DISTINCT FROM 9.9 THEN
    RAISE EXCEPTION 'FAIL [F2 abgerundet]: %', a->'msg'->0; END IF;
  -- gebrochenes Ziel wird nicht gerundet angezeigt
  INSERT INTO core.config (package, category, key, value) VALUES ('core','advisor','cashflow_buffer_pct','0.125')
    ON CONFLICT (category, key) DO UPDATE SET value = '0.125', package = 'core';
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->'msg'->0->'params'->'target'->>'value')::numeric IS DISTINCT FROM 12.5 THEN
    RAISE EXCEPTION 'FAIL [F2 Ziel 12,5]: %', a->'msg'->0; END IF;
  RAISE NOTICE 'PASS [F2 Puffer abgerundet, Ziel mit Nachkommastelle]';
END $$;
ROLLBACK;
