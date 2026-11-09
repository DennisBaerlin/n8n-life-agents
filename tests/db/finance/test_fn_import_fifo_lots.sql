-- ============================================================
-- test_fn_import_fifo_lots / fn_resolve_cost_basis / Rendite ab erstem Kauf -- Bausteine der Ersteinrichtung. Werte erfunden.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_r JSONB;
    T   DATE := core.fn_today();
    v_acct INT; v_dep INT; v_hold INT; v_d JSONB;
BEGIN
    v_r := finance.fn_import_fifo_lots('[
        {"date":"2024-01-01","kind":"buy","shares":2.0000000012,"gross":100,"fee":1,"row_no":1},
        {"date":"2024-02-01","kind":"buy","shares":2,"gross":120,"fee":1,"row_no":2},
        {"date":"2024-03-01","kind":"sell","shares":1,"gross":70,"fee":1,"row_no":3}]');
    IF jsonb_array_length(v_r->'lots') <> 2 OR (v_r->'lots'->0->>'shares')::numeric <> 1 OR (v_r->'lots'->0->>'orig')::numeric <> 2
       OR (v_r->>'unmatched_sell_shares')::numeric <> 0 THEN RAISE EXCEPTION 'FAIL [F1 FIFO, 8 Stellen]: %', v_r; END IF;
    v_r := finance.fn_import_fifo_lots('[{"date":"2024-01-01","kind":"buy","shares":1,"gross":10,"fee":0,"row_no":1},
        {"date":"2024-02-01","kind":"sell","shares":3,"gross":70,"fee":0,"row_no":2}]');
    IF jsonb_array_length(v_r->'lots') <> 0 OR (v_r->>'unmatched_sell_shares')::numeric <> 2 THEN RAISE EXCEPTION 'FAIL [F2 Ueberverkauf]: %', v_r; END IF;

    -- fn_resolve_cost_basis: Beispiel aus dem Konzept
    v_r := finance.fn_resolve_cost_basis(120.55, 50, 100);
    IF v_r->>'kind' <> 'per_share' OR (v_r->>'cost_total')::numeric <> 6027.50 THEN RAISE EXCEPTION 'FAIL [B1 je Stueck]: %', v_r; END IF;
    v_r := finance.fn_resolve_cost_basis(5000, 50, 100);
    IF v_r->>'kind' <> 'total' OR (v_r->>'cost_total')::numeric <> 5000 THEN RAISE EXCEPTION 'FAIL [B2 gesamt]: %', v_r; END IF;
    IF finance.fn_resolve_cost_basis(100, 1.001, 100)->>'kind' <> 'total' THEN RAISE EXCEPTION 'FAIL [B3 nahe 1]'; END IF;
    IF finance.fn_resolve_cost_basis(100, 50, NULL)->>'kind' <> 'ask' THEN RAISE EXCEPTION 'FAIL [B4 ohne Kurs]'; END IF;
    IF finance.fn_resolve_cost_basis(500, 2, 100)->>'kind' <> 'ask' THEN RAISE EXCEPTION 'FAIL [B5 beide plausibel]'; END IF;

    v_acct := (finance.fn_create_account(jsonb_build_object('name','__t_fp_s__','account_type','cash','currency','EUR','opening_balance',1))->>'account_id')::int;
    -- Rundungs-Staub aus mehr als 8 Stellen: Position geschlossen, kein offener Punkt
    v_r := finance.fn_setup_positions('[{"date":"2024-01-01","kind":"buy","isin":"X1","symbol":"X1","name":"X","shares":1.123456784,"gross":10,"fee":0,"row_no":1,"currency":"EUR"},
        {"date":"2024-02-01","kind":"sell","isin":"X1","symbol":"X1","name":"X","shares":1.123456786,"gross":12,"fee":0,"row_no":2,"currency":"EUR"}]'::jsonb, '{}'::jsonb, v_acct, T);
    IF jsonb_array_length(v_r->'positions') <> 0 OR jsonb_array_length(v_r->'open_items') <> 0 THEN RAISE EXCEPTION 'FAIL [F3 Staub]: %', v_r; END IF;

    -- Einbuchung auf einer ISIN mit Kaeufen: Position wartet auf die Antwort, sonst ginge die Einbuchung verloren
    v_acct := (finance.fn_create_account(jsonb_build_object('name','__t_fp_h__','account_type','cash','currency','EUR','opening_balance',1))->>'account_id')::int;
    v_d := '[{"date":"2024-01-01","kind":"buy","isin":"X2","symbol":"X2","name":"H","shares":2,"gross":20,"fee":0,"row_no":1,"currency":"EUR"},
        {"date":"2024-02-01","kind":"unknown","category":"DELIVERY","type":"FREE_RECEIPT","isin":"X2","symbol":"X2","name":"H","shares":1,"row_no":2,"ext_ref":"r2"}]';
    v_r := finance.fn_setup_positions(v_d, '{}'::jsonb, v_acct, T);
    IF jsonb_array_length(v_r->'positions') <> 0 OR jsonb_array_length(v_r->'open_items') <> 1 THEN RAISE EXCEPTION 'FAIL [F4 wartet]: %', v_r; END IF;
    v_r := finance.fn_setup_positions(v_d, '{"r2":{"amount":5}}'::jsonb, v_acct, T);
    IF (v_r->'positions'->0->>'shares')::numeric <> 3 OR (v_r->'positions'->0->>'cost')::numeric <> 25 THEN RAISE EXCEPTION 'FAIL [F5 zusammen]: %', v_r; END IF;

    -- Rendite: cost_origin='export' zaehlt als Geldfluss ab Kaufdatum, keine Uebernahme-Luecke
    v_acct := (finance.fn_create_account(jsonb_build_object('name','__t_fp_c__','account_type','cash','currency','EUR','opening_balance',1000))->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name','__t_fp_d__','account_type','stocks_depot','currency','EUR','settlement_id',v_acct))->>'account_id')::int;
    v_r := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id',v_dep,'settlement_id',v_acct,'isin','IE00TESTPERF','symbol','PRF','name','P',
             'shares',10,'price_per_share',10,'order_fee',0,'transaction_date',(T-400)::text,'existing_position',true,'cost_origin','export'));
    IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [R0 Setup]: %', v_r; END IF;
    v_hold := (v_r->>'holding_id')::int;
    IF (SELECT cost_origin FROM finance.transactions WHERE holding_id = v_hold AND category='buy') <> 'export' THEN RAISE EXCEPTION 'FAIL [R1 Stempel]'; END IF;
    INSERT INTO finance.market_prices (symbol, as_of, price, currency) VALUES ('PRF', T, 20, 'EUR');
    SELECT d INTO v_d FROM jsonb_array_elements(finance.fn_depot_performance(jsonb_build_object('as_of', T))->'rows') d WHERE (d->>'account_id')::int = v_dep;
    IF (v_d->>'start_date')::date <> T-400 OR (v_d->>'return_pa_pct')::numeric IS NULL OR (v_d->>'return_pa_pct')::numeric <= 50 OR v_d->>'takeover_start_date' IS NOT NULL
       THEN RAISE EXCEPTION 'FAIL [R2 Rendite ab Kauf]: %', v_d; END IF;
END $$;
ROLLBACK;
