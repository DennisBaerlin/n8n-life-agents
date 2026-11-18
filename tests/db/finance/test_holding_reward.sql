-- ============================================================
-- test_holding_reward -- Buchungsart reward (Staking-Ertrag): Form-Gesetz + Einstand (fn_holding_avg_cost)
--   reward = Stueck-Zugang ohne Geldfluss auf dem Verrechnungskonto: amount 0, shares > 0, holding_id gesetzt
--   (CHECK finance_transactions_reward_shape). Einstand: reward zaehlt wie ein Kauf mit Kosten 0.
--   Ablauf (Werte erfunden): nur Ertraege 0.5 -> Bestand 0.5, Einstand 0; Kauf 0.5 fuer 50 -> 1.0, Einstand 50;
--   Verkauf 0.25 -> 0.75, Einstand 50; Ertrag 1.0 -> 1.75, Kosten 37.50 -> Einstand 21.42857143.
--   Storno eines Ertrags rechnet zurueck (1.0 weg -> 0.75, Einstand 50).
-- ============================================================
BEGIN;
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_set   INT;
    v_dep   INT;
    v_h     INT;
    v_rw    INT;
    v_res   JSONB;
BEGIN
    v_set := (finance.fn_create_account('{"name":"__t_rw_set__","account_type":"cash","currency":"EUR","bank":"Bitvavo","opening_balance":100}'::jsonb)->>'account_id')::int;
    v_dep := (finance.fn_create_account(jsonb_build_object('name', '__t_rw_dep__', 'account_type', 'crypto_depot',
                 'currency', 'EUR', 'settlement_id', v_set))->>'account_id')::int;
    INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency)
    VALUES (v_dep, NULL, 'RWX', 'RWX', 'EUR') RETURNING id INTO v_h;

    -- Form-Gesetz
    BEGIN
        INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
        VALUES (v_set, v_h, 'reward', -1, 0.1, T - 30, 'x');
        RAISE EXCEPTION 'FAIL [R1 reward mit Betrag <> 0 abgelehnt]';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
        VALUES (v_set, NULL, 'reward', 0, 0.1, T - 30, 'x');
        RAISE EXCEPTION 'FAIL [R2 reward ohne Position abgelehnt]';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
        VALUES (v_set, v_h, 'reward', 0, -0.1, T - 30, 'x');
        RAISE EXCEPTION 'FAIL [R3 reward mit Stueck <= 0 abgelehnt]';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS [R1-R3 Form-Gesetz]';

    -- nur Ertraege: Einstand 0, Bestand zaehlt, Konto-Saldo unveraendert
    INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
    VALUES (v_set, v_h, 'reward', 0, 0.2, T - 30, 'Staking RWX'), (v_set, v_h, 'reward', 0, 0.3, T - 29, 'Staking RWX');
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_h) <> 0.5
       OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h) IS DISTINCT FROM 0
       OR finance.fn_get_balance(v_set) <> 100 THEN
        RAISE EXCEPTION 'FAIL [R4 nur Ertraege]: shares % avg % bal %', (SELECT shares FROM finance.depot_holdings WHERE id = v_h),
            (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h), finance.fn_get_balance(v_set);
    END IF;

    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_dep, 'settlement_id', v_set,
                 'symbol', 'RWX', 'name', 'RWX', 'shares', 0.5, 'price_per_share', 100, 'order_fee', 0,
                 'transaction_date', (T - 20)::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'holding_id')::int <> v_h THEN
        RAISE EXCEPTION 'FAIL [R5 Kauf auf dieselbe Position]: %', v_res; END IF;
    IF (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h) <> 50 THEN
        RAISE EXCEPTION 'FAIL [R5b Einstand nach Kauf]: %', (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h); END IF;

    v_res := finance.fn_book_stock_sell(jsonb_build_object('price_currency_confirmed', true, 'depot_id', v_dep, 'settlement_id', v_set, 'holding_id', v_h,
                 'shares', 0.25, 'price_per_share', 120, 'order_fee', 0, 'transaction_date', (T - 15)::text));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h) <> 50 THEN
        RAISE EXCEPTION 'FAIL [R6 Verkauf laesst Einstand]: %', v_res; END IF;

    INSERT INTO finance.transactions (account_id, holding_id, category, amount, shares, transaction_date, description)
    VALUES (v_set, v_h, 'reward', 0, 1.0, T - 10, 'Staking RWX') RETURNING id INTO v_rw;
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_h) <> 1.75
       OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h) <> 21.42857143 THEN
        RAISE EXCEPTION 'FAIL [R7 Ertrag senkt den Einstand]: shares % avg %', (SELECT shares FROM finance.depot_holdings WHERE id = v_h),
            (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h); END IF;

    v_res := finance.fn_void_transaction(jsonb_build_object('transaction_id', v_rw));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (SELECT shares FROM finance.depot_holdings WHERE id = v_h) <> 0.75
       OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h) <> 50 THEN
        RAISE EXCEPTION 'FAIL [R8 Storno eines Ertrags]: %', v_res; END IF;
    RAISE NOTICE 'PASS [R4-R8 Einstand mit Ertraegen]';
END $$;
ROLLBACK;
