-- tests/db/finance/test_recalc2_app_screens.sql
-- Zweitrechnung Mini-App: die Zahlen der Bildschirme nur lesend aufgerufen und gegen von Hand summierte
-- Einzelwerte geprueft. Werte erfunden.
-- Regel des Bildschirms "Vermoegen" (fn-Kopf): Besitz = alle nicht-negativen Anlagearten, Schulden = Kredite,
--   Netto (Hero) = Besitz - Schulden; "Schnell verfuegbar" = Konten + P2P + Depot, "Langfristig gebunden" = Festgeld +
--   Immobilie + Vorsorge; Anteil je Anlageart = Wert / Besitz x 100, eine Nachkommastelle; die Teile ergeben die Zeile.
--   Fixture: Giro 10.000,00 + Tagesgeld 5.250,50 (Konten 15.250,50), Depot 10 Stueck x 101,50 = 1.015,00, P2P 1.000,00,
--   Festgeld 20.000,00, Immobilie 300.000,00, Kredit -180.000,55.
--   (1) Besitz 337.265,50; schnell 17.265,50; gebunden 320.000,00; Schulden 180.000,55; Netto 157.264,95.
--   (2) Anteile: Konten 15.250,50 / 337.265,50 = 4,52 % -> 4,5; Depot 0,30 -> 0,3; P2P 0,30 -> 0,3; Festgeld 5,93 -> 5,9;
--       Immobilie 88,95 -> 89,0 (PowerShell-Gegenrechnung, kaufmaennisch gerundet).
--   (3) Aufklappen Konten: Giro 10.000,00 + Tagesgeld 5.250,50 = Zeile 15.250,50.
--   (4) Bildschirm "Kredite": Hero = Restschuld 180.000,55 = Schulden-Zeile der Vermoegen-Seite.
--   (5) Bildschirm "Depot": Hero = 1.015,00 = Depot-Zeile der Vermoegen-Seite.
BEGIN;

DO $$
DECLARE
  v_giro int; v_tg int; v_dep int; v_p2p int; v_fd int; v_la int; v_rp int; v_lid int;
  v jsonb; v_liq jsonb; v_bnd jsonb; v_dbt jsonb; v_it jsonb; v_l jsonb; v_d jsonb;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('r2o', 'Owner Muster', 'owner');
  -- Bestand neutralisieren (alles im ROLLBACK)
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active';
  UPDATE finance.real_estate SET status = 'sold' WHERE status = 'active';
  UPDATE finance.pension SET current_value = NULL;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2app_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2app_tg__', 'cash', 'EUR', 'active') RETURNING id INTO v_tg;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__r2app_dep__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_dep;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2app_p2p__', 'p2p', 'EUR', 'active') RETURNING id INTO v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__r2app_fd__', 'fixed_deposit', 'EUR', 'active', current_date + 300) RETURNING id INTO v_fd;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2app_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;
  UPDATE finance.account_balances SET balance = 10000.00 WHERE account_id = v_giro;
  UPDATE finance.account_balances SET balance = 5250.50 WHERE account_id = v_tg;
  UPDATE finance.account_balances SET balance = 1000.00 WHERE account_id = v_p2p;
  UPDATE finance.account_balances SET balance = 20000.00 WHERE account_id = v_fd;
  UPDATE finance.account_balances SET balance = -180000.55 WHERE account_id = v_la;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_dep, 'R2A00000001', 'R2AW', 'Welt-ETF', 10, 90, 'EUR', 'world');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('R2AW', 101.50, 'EUR', current_date);
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__r2app_haus__', 300000.00, 'active');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2app_rate__', v_giro, -950, 'month', current_date + 5, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__r2app_kredit__', 3.4, 'active', v_la, v_giro, v_rp) RETURNING id INTO v_lid;

  v := finance.fn_app_screen_overview('{"person_id":"r2o","params":{}}');
  IF (v->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 157264.95 THEN
    RAISE EXCEPTION 'FAIL [1a] Netto: erwartet 157264.95, got %', v->'hero'; END IF;
  IF (v->'hero'->'note'->'params'->'assets'->>'value')::numeric IS DISTINCT FROM 337265.50
     OR (v->'hero'->'note'->'params'->'debts'->>'value')::numeric IS DISTINCT FROM 180000.55 THEN
    RAISE EXCEPTION 'FAIL [1b] Besitz/Schulden-Note: %', v->'hero'->'note'; END IF;
  SELECT s INTO v_liq FROM jsonb_array_elements(v->'sections') s WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_liquid');
  SELECT s INTO v_bnd FROM jsonb_array_elements(v->'sections') s WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_bound');
  SELECT s INTO v_dbt FROM jsonb_array_elements(v->'sections') s WHERE s->'title' = core.fn_ui_tpl('finance.app.overview.section_debts');
  IF (v_liq->'value'->>'value')::numeric IS DISTINCT FROM 17265.50 OR (v_bnd->'value'->>'value')::numeric IS DISTINCT FROM 320000.00 THEN
    RAISE EXCEPTION 'FAIL [1c] Abschnitte: schnell % / gebunden %', v_liq->'value', v_bnd->'value'; END IF;
  IF (v_dbt->'items'->0->'value'->>'value')::numeric IS DISTINCT FROM 180000.55 THEN
    RAISE EXCEPTION 'FAIL [1d] Schulden-Zeile: %', v_dbt; END IF;
  RAISE NOTICE 'PASS [1] Vermoegen: Netto, Besitz, Schulden, Liquiditaets-Leiter';

  IF EXISTS (
      SELECT 1 FROM (VALUES ('cash', 4.5), ('depot', 0.3), ('p2p', 0.3), ('fixed_deposit', 5.9), ('real_estate', 89.0)) e(bucket, pct)
       WHERE NOT EXISTS (
         SELECT 1 FROM jsonb_array_elements((v_liq->'items') || (v_bnd->'items')) i
          WHERE i->'label'->>'value' = e.bucket AND (i->'progress'->>'pct')::numeric = e.pct)) THEN
    RAISE EXCEPTION 'FAIL [2] Anteile: % %', v_liq->'items', v_bnd->'items'; END IF;
  RAISE NOTICE 'PASS [2] Anteile am Besitz 4,5 / 0,3 / 0,3 / 5,9 / 89,0';

  SELECT i INTO v_it FROM jsonb_array_elements(v_liq->'items') i WHERE i->'label'->>'value' = 'cash';
  IF (v_it->'value'->>'value')::numeric IS DISTINCT FROM 15250.50
     OR (SELECT sum((d->'value'->>'value')::numeric) FROM jsonb_array_elements(v_it->'details') d) IS DISTINCT FROM 15250.50 THEN
    RAISE EXCEPTION 'FAIL [3] Konten-Zeile = Summe der Konten: %', v_it; END IF;
  RAISE NOTICE 'PASS [3] Aufklappen: Konten ergeben die Zeile';

  v_l := finance.fn_app_screen_loans('{"person_id":"r2o","params":{}}');
  IF (v_l->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 180000.55 THEN
    RAISE EXCEPTION 'FAIL [4] Kredite-Hero = Schulden-Zeile: %', v_l->'hero'; END IF;
  RAISE NOTICE 'PASS [4] Kredite-Bildschirm = Schulden der Vermoegen-Seite';

  v_d := finance.fn_app_screen_depot('{"person_id":"r2o","params":{}}');
  IF (v_d->'hero'->'value'->>'value')::numeric IS DISTINCT FROM 1015.00 THEN
    RAISE EXCEPTION 'FAIL [5] Depot-Hero = Depot-Zeile: %', v_d->'hero'; END IF;
  RAISE NOTICE 'PASS [5] Depot-Bildschirm = Depot-Zeile der Vermoegen-Seite';
END $$;

ROLLBACK;
