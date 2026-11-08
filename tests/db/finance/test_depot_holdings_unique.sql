-- ============================================================
-- test_depot_holdings_unique -- die zwei partiellen UNIQUE-Indizes auf finance.depot_holdings sind das Gesetz
--   finance_depot_holdings_isin_uq   (account_id, isin)    WHERE isin IS NOT NULL
--   finance_depot_holdings_symbol_uq (account_id, symbol)  WHERE isin IS NULL  (Krypto/Symbol-Positionen ohne ISIN)
--   Je Index: zweiter Insert -> unique_violation; das Praedikat laesst Legitimes zu (anderes Depot, ISIN vs. ohne ISIN).
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_cash   INT;
    v_depot  INT;
    v_depot2 INT;
    v_hit    BOOLEAN;
BEGIN
    v_cash   := (finance.fn_create_account(jsonb_build_object('name', '__t_hu_cash__', 'account_type', 'cash', 'currency', 'EUR'))->>'account_id')::int;
    v_depot  := (finance.fn_create_account(jsonb_build_object('name', '__t_hu_depot1__', 'account_type', 'stocks_depot', 'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;
    v_depot2 := (finance.fn_create_account(jsonb_build_object('name', '__t_hu_depot2__', 'account_type', 'stocks_depot', 'currency', 'EUR', 'settlement_id', v_cash))->>'account_id')::int;

    -- ===== isin_uq =====
    INSERT INTO finance.depot_holdings (account_id, symbol, isin, name) VALUES (v_depot, 'ZZA', 'IE00ZZUNIQ01', 'ZZ A');
    v_hit := false;
    BEGIN
        INSERT INTO finance.depot_holdings (account_id, symbol, isin, name) VALUES (v_depot, 'ZZB', 'IE00ZZUNIQ01', 'ZZ B');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%finance_depot_holdings_isin_uq%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [isin_uq]: zweite Position mit derselben ISIN im selben Depot akzeptiert'; END IF;
    -- dieselbe ISIN in einem anderen Depot ist erlaubt
    INSERT INTO finance.depot_holdings (account_id, symbol, isin, name) VALUES (v_depot2, 'ZZA', 'IE00ZZUNIQ01', 'ZZ A');
    RAISE NOTICE 'PASS [isin_uq]: gleiche ISIN im selben Depot -> unique_violation, anderes Depot erlaubt';

    -- ===== symbol_uq (nur ohne ISIN) =====
    INSERT INTO finance.depot_holdings (account_id, symbol, name) VALUES (v_depot, 'ZZCOIN', 'ZZ Coin');
    v_hit := false;
    BEGIN
        INSERT INTO finance.depot_holdings (account_id, symbol, name) VALUES (v_depot, 'ZZCOIN', 'ZZ Coin Zwei');
    EXCEPTION WHEN unique_violation THEN v_hit := SQLERRM LIKE '%finance_depot_holdings_symbol_uq%'; END;
    IF NOT v_hit THEN RAISE EXCEPTION 'FAIL [symbol_uq]: zweite ISIN-lose Position mit demselben Symbol im selben Depot akzeptiert'; END IF;
    -- gleiches Symbol mit ISIN (andere Position) und in anderem Depot sind erlaubt
    INSERT INTO finance.depot_holdings (account_id, symbol, isin, name) VALUES (v_depot, 'ZZCOIN', 'IE00ZZUNIQ02', 'ZZ Coin ETF');
    INSERT INTO finance.depot_holdings (account_id, symbol, name) VALUES (v_depot2, 'ZZCOIN', 'ZZ Coin');
    RAISE NOTICE 'PASS [symbol_uq]: gleiches Symbol ohne ISIN im selben Depot -> unique_violation, mit ISIN/anderes Depot erlaubt';
END $$;
ROLLBACK;
