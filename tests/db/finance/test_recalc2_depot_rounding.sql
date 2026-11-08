-- tests/db/finance/test_recalc2_depot_rounding.sql
-- Vermoegen-Seite und Depot-Hero runden je Anlageart genau einmal, aus den ungerundeten finance.networth_items.
-- Ein Depot mit zwei Klassen: 30,015 + 20,005 = 50,020 -> 50,02; aus je Klasse gerundeten Werten wuerden 50,03.
BEGIN;

DO $$
DECLARE
  v_giro int; v_dep int; v_kdep int; v jsonb; v_row numeric; v_det numeric; v_hero numeric; v_kid numeric; v_lo numeric;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('r2f1', 'Owner Muster', 'owner'), ('r2f1k', 'Kind Muster', 'child');
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active';
  UPDATE finance.real_estate SET status = 'sold' WHERE status = 'active';
  UPDATE finance.pension SET current_value = NULL;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f1_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__r2f1_dep__', 'stocks_depot', 'EUR', 'active', v_giro, 'r2f1') RETURNING id INTO v_dep;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__r2f1_kdep__', 'stocks_depot', 'EUR', 'active', v_giro, 'r2f1k') RETURNING id INTO v_kdep;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class) VALUES
    (v_dep, 'R2F00000001', 'R2FW', 'Welt', 3, 10.005, 'EUR', 'world'),
    (v_dep, 'R2F00000002', 'R2FB', 'Anleihen', 1, 20.005, 'EUR', 'bonds'),
    (v_kdep, 'R2F00000003', 'R2FK', 'Kind Welt', 3, 10.005, 'EUR', 'world'),
    (v_kdep, 'R2F00000004', 'R2FL', 'Kind Anleihen', 1, 20.005, 'EUR', 'bonds');

  v := finance.fn_app_screen_overview('{"person_id":"r2f1","params":{}}');
  SELECT (i->'value'->>'value')::numeric, (SELECT sum((d->'value'->>'value')::numeric) FROM jsonb_array_elements(i->'details') d)
    INTO v_row, v_det
    FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
   WHERE i->'label'->>'value' = 'depot' AND s->'title'->>'value' = 'finance.app.overview.section_liquid';
  IF v_row IS DISTINCT FROM 50.02 OR v_det IS DISTINCT FROM 50.02 THEN
    RAISE EXCEPTION 'FAIL [F1] Depot-Zeile: erwartet 50.02 = Aufklappen, got Zeile % / Aufklappen %', v_row, v_det; END IF;
  v_hero := (v->'hero'->'value'->>'value')::numeric;
  IF v_hero IS DISTINCT FROM 50.02 THEN RAISE EXCEPTION 'FAIL [F1b] Hero: erwartet 50.02, got %', v_hero; END IF;

  SELECT (i->'value'->>'value')::numeric,
         (SELECT (d->'value'->>'value')::numeric FROM jsonb_array_elements(i->'details') d WHERE d->'label'->>'value' = 'depot')
    INTO v_kid, v_lo
    FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
   WHERE s->'title'->>'value' = 'finance.app.overview.section_kids';
  IF v_kid IS DISTINCT FROM 50.02 OR v_lo IS DISTINCT FROM 50.02 THEN
    RAISE EXCEPTION 'FAIL [F1c] Kind: erwartet 50.02, got Zeile % / Depot %', v_kid, v_lo; END IF;

  v := finance.fn_app_screen_depot('{"person_id":"r2f1","params":{}}');
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 50.02 THEN
    RAISE EXCEPTION 'FAIL [F1d] Depot-Hero: %', v->'hero'; END IF;

  -- Hero ist die Summe der sichtbaren Zeilen: zwei Anlagearten
  UPDATE finance.account_balances SET balance = 0.005 WHERE account_id = v_giro;
  v := finance.fn_app_screen_overview('{"person_id":"r2f1","params":{}}');
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM (
       SELECT sum((i->'value'->>'value')::numeric) FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
        WHERE s->'title'->>'value' = 'finance.app.overview.section_liquid') THEN
    RAISE EXCEPTION 'FAIL [F1e] Hero ungleich Summe der Zeilen: %', v; END IF;

  -- Fast-null-Saldo bleibt keine Schulden-Zeile mit 0,00
  UPDATE finance.account_balances SET balance = -0.004 WHERE account_id = v_giro;
  v := finance.fn_app_screen_overview('{"person_id":"r2f1","params":{}}');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
              WHERE s->'title'->>'value' = 'finance.app.overview.section_debts') THEN
    RAISE EXCEPTION 'FAIL [F1f] Ueberzogen-Zeile mit 0,00: %', v; END IF;
  RAISE NOTICE 'PASS [F1] einmal gerundet: Zeile, Hero, Kind, Depot-Hero';
END $$;

ROLLBACK;

-- Konto ohne Wechselkurs: im Aufklappen steht der Grund, auch bei mehr als acht Konten
BEGIN;
DO $$
DECLARE
  v_chf int; v jsonb; v_det jsonb; i int; v_id int;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('r2f2', 'Owner Muster', 'owner');
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active';
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__r2f2_chf__', 'cash', 'CHF', 'active', 'r2f2') RETURNING id INTO v_chf;
  UPDATE finance.account_balances SET balance = 700 WHERE account_id = v_chf;
  FOR i IN 1..9 LOOP
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('__r2f2_' || i || '__', 'cash', 'EUR', 'active', 'r2f2') RETURNING id INTO v_id;
    UPDATE finance.account_balances SET balance = 100 + i WHERE account_id = v_id;
  END LOOP;
  v := finance.fn_app_screen_overview('{"person_id":"r2f2","params":{}}');
  SELECT i2->'details' INTO v_det FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i2
   WHERE i2->'label'->>'value' = 'cash';
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_det) d
                  WHERE d->>'label' = '__r2f2_chf__' AND d->'value'->>'value' = 'finance.app.overview.d_fx_missing') THEN
    RAISE EXCEPTION 'FAIL [FX1] Grund fehlt oder Zeile unter „weitere“: %', v_det; END IF;
  IF jsonb_array_length(v_det) > 8 THEN RAISE EXCEPTION 'FAIL [FX2] mehr als 8 Zeilen: %', v_det; END IF;
  RAISE NOTICE 'PASS [FX] Wechselkurs fehlt steht beim Konto, Zeile bleibt sichtbar';
END $$;
ROLLBACK;
