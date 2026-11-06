-- tests/db/finance/test_fn_depot_performance.sql
-- finance.fn_depot_performance(p jsonb) + View finance.depot_performance — Depot-Rendite (XIRR) je Depot und gesamt.
--   1) Stichtag 30.06.2026. Depot A (genau 365 Tage): Kauf, ausverkaufte Position, Dividende -> 10,00 % pro Jahr,
--      Wert nur der Bestand. Depot B (Uebernahme MIT Kurs am Uebernahme-Tag, 180 Tage): Startwert = Marktwert am
--      Uebernahme-Tag (nicht der Einstand), unter 1 Jahr nur Rendite seit Beginn (+10,00 %), keine p.a.-Zahl.
--      Depot C (Uebernahme OHNE Kurs am Tag): Start = erster Kurs-Tag danach, ein Kauf dazwischen faellt in den
--      Startwert, Hinweis-Datum. Kinder-Depot D eigene Zeile (10 % p.a. ueber 730 Tage), nicht in „gesamt".
--      Leeres Depot: no_flows. Gesamt = gepoolte Fluesse von A+B+C (= fn_xirr derselben Fluesse, Barwert 0).
--   2) Position ohne Kurs -> Wert NULL + no_price (nie 0, nie Kaufwert), Gesamt ebenso; Uebernahme ohne Kurs ab dem
--      Uebernahme-Tag -> no_price; Kurs ohne Wechselkurs -> no_fx; mit Wechselkurs in EUR.
--   3) Personen-Sicht wie die App: Kind sieht nur sein Depot (ohne Kinder-Kennzeichen, gesamt = eigenes), Owner = alles.
--   4) Muell -> bad_request; View: eine Zeile je aktivem Depot + eine Gesamt-Zeile.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro INT; v_kid_cash INT; v_a INT; v_b INT; v_c INT; v_d INT; v_g INT; v_e INT; v_f INT; v_h INT;
  h_a1 INT; h_a2 INT; h_a3 INT; h_b1 INT; h_c1 INT; h_d1 INT; h_e1 INT; h_f1 INT; h_h1 INT;
  v jsonb; v_row jsonb; v_tot jsonb; v_names text[]; v_r numeric; v_npv numeric; v_n int;
  c_as_of CONSTANT date := DATE '2026-06-30';
  g1 uuid := gen_random_uuid(); g2 uuid := gen_random_uuid(); g3 uuid := gen_random_uuid();
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  -- Gesamt-Zeile nur aus den Test-Depots (Seed-/Fixture-Depots der Test-DB ruhen bis zum ROLLBACK)
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active' AND account_type IN ('stocks_depot', 'crypto_depot');
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('dpf_owner', 'Owner Beispiel', 'owner'), ('dpf_kid', 'Kind Beispiel', 'child');

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__dpf_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__dpf_kid_cash__', 'cash', 'EUR', 'active', 'dpf_kid') RETURNING id INTO v_kid_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_a__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_a;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_b__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_b;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_c__', 'crypto_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_c;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__dpf_d__', 'stocks_depot', 'EUR', 'active', v_kid_cash, 'dpf_kid') RETURNING id INTO v_d;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_g__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_g;

  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_a, 'DPF00000001', 'DPFA1', 'A eins', 'EUR') RETURNING id INTO h_a1;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_a, 'DPF00000002', 'DPFA2', 'A zwei', 'EUR') RETURNING id INTO h_a2;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_a, 'DPF00000003', 'DPFA3', 'A drei', 'EUR') RETURNING id INTO h_a3;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_b, 'DPF00000004', 'DPFB1', 'B eins', 'EUR') RETURNING id INTO h_b1;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_c, NULL, 'DPFC1', 'C eins', 'EUR') RETURNING id INTO h_c1;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_d, 'DPF00000006', 'DPFD1', 'D eins', 'EUR') RETURNING id INTO h_d1;

  -- Depot A: 3 Kaeufe am 30.06.2025 (-2500); am 30.06.2026 Verkauf +550 (A2 ausverkauft), Dividende +50,
  -- Bestand 1100 + 1050 -> +2750 nach genau 365 Tagen = 10 % (ohne die Dividende waeren es 8 %)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
    (v_giro, -1000, '2025-06-30', 'buy', h_a1, 10),
    (v_giro,  -500, '2025-06-30', 'buy', h_a2, 5),
    (v_giro,   550, '2026-06-30', 'sell', h_a2, -5),
    (v_giro, -1000, '2025-06-30', 'buy', h_a3, 10);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id) VALUES
    (v_giro, 50, '2026-06-30', 'dividend', h_a3);
  -- Depot B: Uebernahme 10 Stueck zu 50 (Einstand 500) am 01.01.2026; Kurs an dem Tag 80 -> Startwert 800, nicht 500
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id) VALUES
    (v_giro, -500, '2026-01-01', 'buy', h_b1, 10, 50, g1);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES
    (v_giro, 500, '2026-01-01', 'position_takeover', g1);
  -- Depot C: Uebernahme 5 Stueck am 10.01.2026 ohne Kurs an dem Tag, Kauf 5 Stueck am 12.01. (-150); erster Kurs
  -- 15.01. = 30 -> Startwert 10 x 30 = 300 am 15.01., der Kauf vom 12.01. faellt in den Startwert
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id) VALUES
    (v_giro, -100, '2026-01-10', 'buy', h_c1, 5, 20, g2);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES
    (v_giro, 100, '2026-01-10', 'position_takeover', g2);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
    (v_giro, -150, '2026-01-12', 'buy', h_c1, 5);
  -- Kinder-Depot D: -1000 am 30.06.2024, Wert 1210 nach 730 Tagen = 10 % pro Jahr
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
    (v_kid_cash, -1000, '2024-06-30', 'buy', h_d1, 10);

  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('DPFA1', 110, 'EUR', c_as_of), ('DPFA3', 105, 'EUR', c_as_of),
    ('DPFB1', 70, 'EUR', '2025-12-01'), ('DPFB1', 80, 'EUR', '2026-01-01'), ('DPFB1', 88, 'EUR', c_as_of),
    ('DPFC1', 30, 'EUR', '2026-01-15'), ('DPFC1', 33, 'EUR', c_as_of),
    ('DPFD1', 121, 'EUR', c_as_of),
    -- ein Kurs NACH dem Stichtag zaehlt nie
    ('DPFA1', 999, 'EUR', c_as_of + 1);

  -- ===== 1) Haushalt =====
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->>'as_of')::date IS DISTINCT FROM c_as_of THEN
    RAISE EXCEPTION 'FAIL [1a] ok + as_of, got %', v; END IF;
  SELECT array_agg(COALESCE(r->>'depot_name', '<gesamt>') ORDER BY o) INTO v_names
    FROM jsonb_array_elements(v->'rows') WITH ORDINALITY AS t(r, o) WHERE r->>'depot_name' IS NULL OR r->>'depot_name' LIKE '__dpf_%';
  IF v_names IS DISTINCT FROM ARRAY['__dpf_a__', '__dpf_b__', '__dpf_c__', '__dpf_g__', '__dpf_d__', '<gesamt>'] THEN
    RAISE EXCEPTION 'FAIL [1b] Reihenfolge: Haushalt nach Wert, Kinder-Depot danach, gesamt zuletzt, got %', v_names; END IF;

  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_a__';
  IF (v_row->>'return_pa_pct')::numeric IS DISTINCT FROM 10.00 OR jsonb_typeof(v_row->'return_since_start_pct') <> 'null'
     OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 2150.00 OR (v_row->>'start_date')::date IS DISTINCT FROM DATE '2025-06-30'
     OR (v_row->>'period_days')::int IS DISTINCT FROM 365 OR (v_row->>'is_child')::boolean OR (v_row->>'is_total')::boolean
     OR (v_row->>'account_id')::int IS DISTINCT FROM v_a
     OR jsonb_typeof(v_row->'missing_reason') <> 'null' OR jsonb_typeof(v_row->'takeover_start_date') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1c] Depot A: 10,00 %% p.a. (Verkauf + Dividende zaehlen), Wert 2150, 365 Tage, got %', v_row; END IF;

  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_b__';
  IF jsonb_typeof(v_row->'return_pa_pct') <> 'null' OR (v_row->>'return_since_start_pct')::numeric IS DISTINCT FROM 10.00
     OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 880.00 OR (v_row->>'start_date')::date IS DISTINCT FROM DATE '2026-01-01'
     OR (v_row->>'period_days')::int IS DISTINCT FROM 180 OR jsonb_typeof(v_row->'takeover_start_date') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [1d] Depot B: Startwert = Marktwert am Uebernahme-Tag (800, nicht 500), unter 1 Jahr nur seit Beginn +10 %%, got %', v_row; END IF;

  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_c__';
  IF jsonb_typeof(v_row->'return_pa_pct') <> 'null' OR (v_row->>'return_since_start_pct')::numeric IS DISTINCT FROM 10.00
     OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 330.00 OR (v_row->>'start_date')::date IS DISTINCT FROM DATE '2026-01-15'
     OR (v_row->>'takeover_start_date')::date IS DISTINCT FROM DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [1e] Depot C: Start am ersten Kurs-Tag 15.01. (300 inkl. Kauf vom 12.01.), Hinweis-Datum, +10 %%, got %', v_row; END IF;

  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_d__';
  IF (v_row->>'is_child')::boolean IS NOT TRUE OR (v_row->>'return_pa_pct')::numeric IS DISTINCT FROM 10.00
     OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 1210.00 OR v_row->>'owner_person_id' <> 'dpf_kid' THEN
    RAISE EXCEPTION 'FAIL [1f] Kinder-Depot: eigene Zeile, 10 %% p.a. ueber 730 Tage, got %', v_row; END IF;

  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_g__';
  IF v_row->>'missing_reason' <> 'no_flows' OR jsonb_typeof(v_row->'return_pa_pct') <> 'null'
     OR jsonb_typeof(v_row->'return_since_start_pct') <> 'null' OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [1g] leeres Depot: no_flows, keine Rendite, got %', v_row; END IF;

  -- Gesamt (ohne Kinder-Depot): gepoolte Fluesse A+B+C
  SELECT r INTO v_tot FROM jsonb_array_elements(v->'rows') r WHERE (r->>'is_total')::boolean;
  v_r := finance.fn_xirr(ARRAY['2025-06-30', '2026-01-01', '2026-01-15', '2026-06-30']::date[],
                         ARRAY[-2500, -800, -300, 3960]::numeric[]);
  SELECT sum(a / power(1 + v_r, (d - DATE '2025-06-30') / 365.0)) INTO v_npv
    FROM unnest(ARRAY['2025-06-30', '2026-01-01', '2026-01-15', '2026-06-30']::date[], ARRAY[-2500, -800, -300, 3960]::numeric[]) u(d, a);
  IF v_tot IS NULL OR jsonb_typeof(v_tot->'account_id') <> 'null' OR jsonb_typeof(v_tot->'depot_name') <> 'null'
     OR (v_tot->>'value_eur')::numeric IS DISTINCT FROM 3360.00 OR (v_tot->>'start_date')::date IS DISTINCT FROM DATE '2025-06-30'
     OR (v_tot->>'return_pa_pct')::numeric IS DISTINCT FROM round(100 * v_r, 2) OR abs(v_npv) > 1e-6
     OR jsonb_typeof(v_tot->'return_since_start_pct') <> 'null'
     OR (v_tot->>'takeover_start_date')::date IS DISTINCT FROM DATE '2026-01-15' THEN
    RAISE EXCEPTION 'FAIL [1h] gesamt = XIRR der gepoolten Fluesse (%, Barwert %), Wert 3360 ohne Kind, got %', v_r, v_npv, v_tot; END IF;
  RAISE NOTICE 'PASS [1] Depot-Rendite: p.a. ab 365 Tagen, Uebernahme zum Marktwert, Kinder-Depot eigene Zeile, gesamt gepoolt';

  -- ===== 2) Luecken: nie 0, nie Kaufwert =====
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_e__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_e;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_e, 'DPF00000007', 'DPFE1', 'E eins', 'EUR') RETURNING id INTO h_e1;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
    (v_giro, -100, '2026-02-01', 'buy', h_e1, 2);
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_e__';
  SELECT r INTO v_tot FROM jsonb_array_elements(v->'rows') r WHERE (r->>'is_total')::boolean;
  IF v_row->>'missing_reason' <> 'no_price' OR jsonb_typeof(v_row->'value_eur') <> 'null'
     OR jsonb_typeof(v_row->'return_since_start_pct') <> 'null' OR jsonb_typeof(v_row->'return_pa_pct') <> 'null'
     OR v_tot->>'missing_reason' <> 'no_price' OR jsonb_typeof(v_tot->'value_eur') <> 'null'
     OR jsonb_typeof(v_tot->'return_pa_pct') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2a] Position ohne Kurs: Depot + gesamt Wert NULL + no_price, got % / %', v_row, v_tot; END IF;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_e;

  -- Uebernahme, nach der es nie einen Kurs gab (nur einen davor) -> Startwert unbekannt
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_h__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_h;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_h, 'DPF00000009', 'DPFH1', 'H eins', 'EUR') RETURNING id INTO h_h1;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id) VALUES
    (v_giro, -100, '2026-06-01', 'buy', h_h1, 1, 100, g3);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES
    (v_giro, 100, '2026-06-01', 'position_takeover', g3);
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DPFH1', 90, 'EUR', '2026-05-01');
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_h__';
  IF v_row->>'missing_reason' <> 'no_price' OR jsonb_typeof(v_row->'return_since_start_pct') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2b] Uebernahme ohne Kurs ab dem Uebernahme-Tag -> no_price, got %', v_row; END IF;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_h;

  -- Kurs in CHF ohne Wechselkurs -> no_fx; mit Wechselkurs: 120 CHF / 0,8 = 150 EUR
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_f__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_f;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency, quote_currency)
    VALUES (v_f, 'DPF00000008', 'DPFF1', 'F eins', 'EUR', 'CHF') RETURNING id INTO h_f1;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares) VALUES
    (v_giro, -100, '2026-02-01', 'buy', h_f1, 1);
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DPFF1', 120, 'CHF', c_as_of);
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_f__';
  IF v_row->>'missing_reason' <> 'no_fx' OR jsonb_typeof(v_row->'value_eur') <> 'null' THEN
    RAISE EXCEPTION 'FAIL [2c] Kurs ohne Wechselkurs -> no_fx, Wert NULL, got %', v_row; END IF;
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR', 'CHF', 0.8, c_as_of);
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_f__';
  IF jsonb_typeof(v_row->'missing_reason') <> 'null' OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 150.00
     OR (v_row->>'return_since_start_pct')::numeric IS DISTINCT FROM 50.00 THEN
    RAISE EXCEPTION 'FAIL [2d] Fremdwaehrungs-Kurs in EUR (150), +50 %% seit Beginn, got %', v_row; END IF;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_f;
  RAISE NOTICE 'PASS [2] ohne Kurs/Wechselkurs: Wert NULL + Grund, nie 0';

  -- ===== 2b) veralteter Kurs, Stichtag in der Zukunft, alles an einem Tag =====
  -- Stichtag 31.07.: juengster Kurs 30.06. ist 31 Tage alt (> price_stale_days 7) -> Zahl bleibt, price_stale
  v := finance.fn_depot_performance(jsonb_build_object('as_of', DATE '2026-07-31'));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_a__';
  IF (v_row->>'price_stale')::boolean IS NOT TRUE OR jsonb_typeof(v_row->'missing_reason') <> 'null'
     OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 11040.00 THEN   -- 10 x 999 (Kurs 01.07.) + 10 x 105
    RAISE EXCEPTION 'FAIL [2e] veralteter Kurs: Wert + Rendite bleiben, price_stale, got %', v_row; END IF;
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v->'rows') r WHERE (r->>'price_stale')::boolean) THEN
    RAISE EXCEPTION 'FAIL [2f] am 30.06. ist kein Kurs veraltet'; END IF;
  IF (finance.fn_depot_performance(jsonb_build_object('as_of', core.fn_today() + 30))->>'as_of')::date IS DISTINCT FROM core.fn_today() THEN
    RAISE EXCEPTION 'FAIL [2g] Stichtag nie nach heute'; END IF;
  -- Uebernahme mit Kurs am selben Tag = Stichtag: 0,00 % seit Beginn statt „nicht berechenbar"
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dpf_s__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_e;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency) VALUES (v_e, 'DPF00000010', 'DPFS1', 'S eins', 'EUR') RETURNING id INTO h_e1;
  g1 := gen_random_uuid();
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, unit_price, group_id) VALUES
    (v_giro, -50, c_as_of, 'buy', h_e1, 2, 25, g1);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id) VALUES
    (v_giro, 50, c_as_of, 'position_takeover', g1);
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DPFS1', 40, 'EUR', c_as_of);
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of));
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_s__';
  IF (v_row->>'return_since_start_pct')::numeric IS DISTINCT FROM 0.00 OR (v_row->>'period_days')::int IS DISTINCT FROM 0
     OR jsonb_typeof(v_row->'missing_reason') <> 'null' OR (v_row->>'value_eur')::numeric IS DISTINCT FROM 80.00 THEN
    RAISE EXCEPTION 'FAIL [2h] alles an einem Tag: 0,00 %% seit Beginn, Wert 80, got %', v_row; END IF;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_e;
  RAISE NOTICE 'PASS [2b] veralteter Kurs markiert, Stichtag <= heute, Ein-Tages-Depot 0 %%';

  -- ===== 3) Personen-Sicht =====
  v := finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of, 'person_id', 'dpf_kid'));
  SELECT count(*) INTO v_n FROM jsonb_array_elements(v->'rows') r;
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE r->>'depot_name' = '__dpf_d__';
  SELECT r INTO v_tot FROM jsonb_array_elements(v->'rows') r WHERE (r->>'is_total')::boolean;
  IF v_n <> 2 OR (v_row->>'is_child')::boolean OR (v_tot->>'return_pa_pct')::numeric IS DISTINCT FROM 10.00
     OR (v_tot->>'value_eur')::numeric IS DISTINCT FROM 1210.00 THEN
    RAISE EXCEPTION 'FAIL [3a] Kind: nur eigenes Depot (ohne Kinder-Kennzeichen) + gesamt = eigenes, got %', v; END IF;
  IF finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of, 'person_id', 'dpf_owner'))
     <> finance.fn_depot_performance(jsonb_build_object('as_of', c_as_of)) THEN
    RAISE EXCEPTION 'FAIL [3b] Owner = Haushalts-Sicht'; END IF;
  RAISE NOTICE 'PASS [3] Personen-Sicht wie die App';

  -- ===== 4) Muell + View =====
  IF finance.fn_depot_performance('[1]') <> '{"ok":false,"code":"bad_request"}'::jsonb
     OR finance.fn_depot_performance('{"person_id":42}') <> '{"ok":false,"code":"bad_request"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [4a] Muell -> bad_request'; END IF;
  IF (finance.fn_depot_performance(NULL)->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [4b] NULL = Standard'; END IF;
  IF finance.fn_depot_performance('{"as_of":"yesterday"}')->>'as_of' IS DISTINCT FROM (core.fn_today() - 1)::text
     OR finance.fn_depot_performance('{"as_of":"kein Datum"}')->>'code' IS DISTINCT FROM 'invalid_date' THEN
    RAISE EXCEPTION 'FAIL [4b2] as_of relativ aufgeloest, Unsinn -> invalid_date ohne RAISE'; END IF;
  SELECT count(*) INTO v_n FROM finance.depot_performance WHERE depot_name LIKE '__dpf_%';
  IF v_n <> 5 OR (SELECT count(*) FROM finance.depot_performance WHERE is_total) <> 1 THEN
    RAISE EXCEPTION 'FAIL [4c] View: 5 aktive Test-Depots + eine Gesamt-Zeile, got %', v_n; END IF;
  PERFORM account_id, depot_name, owner_person_id, is_child, is_total, value_eur, start_date, period_days,
          return_pa_pct, return_since_start_pct, takeover_start_date, price_stale, missing_reason FROM finance.depot_performance;
  RAISE NOTICE 'PASS [4] bad_request + View';
END $$;
ROLLBACK;
