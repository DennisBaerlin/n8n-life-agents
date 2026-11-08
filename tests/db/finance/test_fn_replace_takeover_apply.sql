-- ============================================================
-- test_fn_replace_takeover_apply -- interner Baustein: neue Lots buchen -> alte Uebernahme-Gruppe voiden -> Audit stempeln
--   Werte erfunden, Daten relativ zu core.fn_today(). Cashkonto 1000 (Stichtag heute-20), Depot daran.
--   A: Uebernahme 10 @ 25 wird durch 2 cash-neutrale Lots (4 + 6 Stueck) ersetzt: eine neue group_id, alte Gruppe weg,
--      Saldo des Verrechnungskontos unveraendert, Audit 'replaced_by_lots' mit replaced_by_group.
--   B: ein cash-Lot (echter Kauf ohne Gegenbuchung) -> cash_lots_count 1, Saldo sinkt um den Kaufbetrag.
--   C: abgelehntes Lot (0 Stueck) -> RAISE, nichts bleibt (Rollback des ganzen Aufrufs).
--   D: unbekannte alte Gruppe -> RAISE, die neuen Lots bleiben nicht zurueck.
-- ============================================================
BEGIN;
DO $$
DECLARE
    T       DATE := core.fn_today();
    v_cash  INT;
    v_depot INT;
    v_a INT; v_b INT; v_c INT;
    v_res   JSONB;
    v_old   UUID;
    v_grp   UUID;
    v_bal   NUMERIC;
    v_n     INT;
    v_caught BOOLEAN;
BEGIN
    v_cash := (finance.fn_create_account(jsonb_build_object('name', '__t_tka_cash__', 'account_type', 'cash', 'currency', 'EUR',
                   'opening_balance', 1000, 'opening_balance_date', (T - 20)::text))->>'account_id')::int;
    v_depot := (finance.fn_create_account(jsonb_build_object('name', '__t_tka_depot__', 'account_type', 'stocks_depot',
                    'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;

    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00TKAAPP01',
                 'symbol', 'TKA', 'name', 'TKA ETF', 'shares', 10, 'price_per_share', 25, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP A: %', v_res; END IF;
    v_a := (v_res->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_a AND category::text = 'buy';
    v_bal := finance.fn_get_balance(v_cash);

    -- ---------- A: cash-neutrale Lots ersetzen die Uebernahme ----------
    v_res := finance.fn_replace_takeover_apply(v_a, v_cash,
        jsonb_build_array(
            jsonb_build_object('date', (T - 60)::text, 'shares', 4, 'price', 20, 'fee', 1, 'cash', false),
            jsonb_build_object('date', (T - 30)::text, 'shares', 6, 'price', 22, 'fee', 0, 'cash', false)),
        ARRAY[v_old], 'TKA');
    v_grp := (v_res->>'group_id')::uuid;
    IF v_grp IS NULL OR (v_res->>'cash_lots_count')::int <> 0 THEN
        RAISE EXCEPTION 'FAIL [A1 Rueckgabe]: %', v_res;
    END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'buy') <> 2
       OR (SELECT count(*) FROM finance.transactions WHERE group_id = v_grp AND category::text = 'position_takeover') <> 2
       OR (SELECT count(*) FROM finance.transactions WHERE holding_id = v_a) <> 2 THEN
        RAISE EXCEPTION 'FAIL [A2 eine neue group_id mit 2 Paaren, alte Paare weg]';
    END IF;
    IF EXISTS (SELECT 1 FROM finance.transactions WHERE group_id = v_old) THEN
        RAISE EXCEPTION 'FAIL [A3]: die alte Uebernahme-Gruppe ist noch da';
    END IF;
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_a) <> 10 THEN
        RAISE EXCEPTION 'FAIL [A4]: Stueckzahl nach dem Ersetzen <> 10';
    END IF;
    IF finance.fn_get_balance(v_cash) <> v_bal THEN
        RAISE EXCEPTION 'FAIL [A5]: Saldo des Verrechnungskontos hat sich bewegt (% -> %)', v_bal, finance.fn_get_balance(v_cash);
    END IF;
    IF (SELECT count(*) FROM finance.transaction_audit WHERE reason = 'replaced_by_lots' AND replaced_by_group = v_grp) <> 2 THEN
        RAISE EXCEPTION 'FAIL [A6 Audit]: erwartet 2 Audit-Zeilen replaced_by_lots (Kauf + Gegenbuchung der alten Gruppe)';
    END IF;
    RAISE NOTICE 'PASS [A Ersetzen]: group_id %, 2 Paare, alte Gruppe weg, Saldo unveraendert, Audit gestempelt', v_grp;

    -- ---------- B: cash-Lot = echter Kauf ohne Gegenbuchung ----------
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00TKABPP01',
                 'symbol', 'TKB', 'name', 'TKB ETF', 'shares', 1, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_b := (v_res->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_b AND category::text = 'buy';
    v_bal := finance.fn_get_balance(v_cash);
    v_res := finance.fn_replace_takeover_apply(v_b, v_cash,
        jsonb_build_array(
            jsonb_build_object('date', (T - 40)::text, 'shares', 1, 'price', 10, 'fee', 0, 'cash', false),
            jsonb_build_object('date', (T - 2)::text,  'shares', 2, 'price', 10, 'fee', 0, 'cash', true)),
        ARRAY[v_old], 'TKB');
    IF (v_res->>'cash_lots_count')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [B1]: cash_lots_count % statt 1', v_res->>'cash_lots_count';
    END IF;
    IF finance.fn_get_balance(v_cash) <> v_bal - 20 THEN
        RAISE EXCEPTION 'FAIL [B2]: Saldo % statt % (cash-Lot 2 x 10 = -20)', finance.fn_get_balance(v_cash), v_bal - 20;
    END IF;
    IF (SELECT shares FROM finance.depot_holdings WHERE id = v_b) <> 3 THEN
        RAISE EXCEPTION 'FAIL [B3]: Stueckzahl % statt 3', (SELECT shares FROM finance.depot_holdings WHERE id = v_b);
    END IF;
    RAISE NOTICE 'PASS [B cash-Lot]: cash_lots_count 1, Saldo -20, Stueckzahl 3';

    -- ---------- C: abgelehntes Lot -> echte Ausnahme ----------
    v_res := finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id', v_depot, 'settlement_id', v_cash, 'isin', 'IE00TKACPP01',
                 'symbol', 'TKC', 'name', 'TKC ETF', 'shares', 5, 'price_per_share', 10, 'order_fee', 0,
                 'transaction_date', (T - 5)::text, 'existing_position', true));
    v_c := (v_res->>'holding_id')::int;
    SELECT group_id INTO v_old FROM finance.transactions WHERE holding_id = v_c AND category::text = 'buy';
    SELECT count(*) INTO v_n FROM finance.transactions WHERE holding_id = v_c;
    v_caught := false;
    BEGIN
        PERFORM finance.fn_replace_takeover_apply(v_c, v_cash,
            jsonb_build_array(jsonb_build_object('date', (T - 40)::text, 'shares', 0, 'price', 10, 'fee', 0, 'cash', false)),
            ARRAY[v_old], 'TKC');
    EXCEPTION WHEN OTHERS THEN
        v_caught := true;
        IF SQLERRM NOT LIKE 'fn_replace_takeover_apply: lot of TKC refused:%' THEN
            RAISE EXCEPTION 'FAIL [C1]: falscher Fehlertext: %', SQLERRM;
        END IF;
    END;
    IF NOT v_caught THEN RAISE EXCEPTION 'FAIL [C2]: ein abgelehntes Lot muss RAISEn'; END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE holding_id = v_c) <> v_n
       OR NOT EXISTS (SELECT 1 FROM finance.transactions WHERE group_id = v_old) THEN
        RAISE EXCEPTION 'FAIL [C3]: nach der Ablehnung hat sich der Bestand veraendert';
    END IF;
    RAISE NOTICE 'PASS [C abgelehntes Lot]: RAISE, alte Gruppe unberuehrt';

    -- ---------- D: unbekannte alte Gruppe -> Ausnahme, die neuen Lots bleiben nicht zurueck ----------
    v_caught := false;
    BEGIN
        PERFORM finance.fn_replace_takeover_apply(v_c, v_cash,
            jsonb_build_array(jsonb_build_object('date', (T - 40)::text, 'shares', 5, 'price', 10, 'fee', 0, 'cash', false)),
            ARRAY[gen_random_uuid()], 'TKC');
    EXCEPTION WHEN OTHERS THEN
        v_caught := true;
    END;
    IF NOT v_caught THEN RAISE EXCEPTION 'FAIL [D1]: eine unbekannte alte Gruppe muss RAISEn'; END IF;
    IF (SELECT count(*) FROM finance.transactions WHERE holding_id = v_c) <> v_n THEN
        RAISE EXCEPTION 'FAIL [D2]: die neuen Lots sind trotz der Ausnahme geblieben';
    END IF;
    RAISE NOTICE 'PASS [D unbekannte Gruppe]: RAISE, Rollback';
END $$;
ROLLBACK;
