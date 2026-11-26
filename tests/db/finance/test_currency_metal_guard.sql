-- ============================================================
-- test_currency_metal_guard — Edelmetalle (finance.currencies.kind = 'metal') sind nur Kurs-Codes, nie Geld-Waehrung.
--   DB-Gesetz: jede Tabelle mit Waehrungs-FK ausser fx_rates zeigt per zusammengesetztem FK (Waehrung, currency_kind)
--   auf currencies(code, kind); currency_kind ist eine konstante GENERATED-Spalte 'fiat'. Struktur (jede solche FK,
--   auch kuenftige) + Verhalten (Konto, Position, Kurs-Waehrung, Kurs) + freundliche Ablehnung in fn_ensure_currency.
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_acct int;
    v_bad  text;
    r      jsonb;
BEGIN
    -- [s] Struktur: jede FK auf finance.currencies ausser fx_rates ist zusammengesetzt mit einer GENERATED-'fiat'-Spalte
    SELECT string_agg(format('%s.%s', c.conrelid::regclass, c.conname), ', ') INTO v_bad
    FROM pg_constraint c
    WHERE c.contype = 'f' AND c.confrelid = 'finance.currencies'::regclass AND c.conrelid <> 'finance.fx_rates'::regclass
      AND NOT (array_length(c.conkey, 1) = 2 AND EXISTS (
            SELECT 1 FROM pg_attribute a
            WHERE a.attrelid = c.conrelid AND a.attnum = c.conkey[2] AND a.attgenerated = 's'
              AND pg_get_expr((SELECT d.adbin FROM pg_attrdef d WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum), a.attrelid)
                  LIKE '%''fiat''%'));
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [s] Waehrungs-FK ohne Metall-Sperre: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM pg_constraint c WHERE c.contype = 'f' AND c.confrelid = 'finance.currencies'::regclass
          AND c.conrelid <> 'finance.fx_rates'::regclass) < 5 THEN
        RAISE EXCEPTION 'FAIL [s] erwartet mindestens 5 Waehrungs-FKs (accounts, depot_holdings x2, market_prices, reserve_entries)';
    END IF;

    -- [k] Konto in XAU -> FK-Fehler
    BEGIN
        INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test__ gold', 'cash', 'XAU');
        RAISE EXCEPTION 'FAIL [k] Konto in XAU angelegt';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- [p] Position in XAG bzw. mit Kurs-Waehrung XAU -> FK-Fehler
    INSERT INTO finance.accounts (name, account_type, currency) VALUES ('__test__ cash', 'cash', 'EUR') RETURNING id INTO v_acct;
    INSERT INTO finance.accounts (name, account_type, currency, settlement_account_id)
    VALUES ('__test__ depot', 'stocks_depot', 'EUR', v_acct) RETURNING id INTO v_acct;
    BEGIN
        INSERT INTO finance.depot_holdings (account_id, symbol, name, currency) VALUES (v_acct, 'TSTA', '__test__ a', 'XAG');
        RAISE EXCEPTION 'FAIL [p] Position in XAG angelegt';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO finance.depot_holdings (account_id, symbol, name, currency, quote_currency) VALUES (v_acct, 'TSTB', '__test__ b', 'EUR', 'XAU');
        RAISE EXCEPTION 'FAIL [p] Kurs-Waehrung XAU angelegt';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- quote_currency NULL bleibt erlaubt (MATCH SIMPLE), Fiat-Position geht
    INSERT INTO finance.depot_holdings (account_id, symbol, name, currency) VALUES (v_acct, 'TSTC', '__test__ c', 'EUR');
    -- [m] Markt-Kurs in XAU -> FK-Fehler
    BEGIN
        INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('TSTC', 1, 'XAU', DATE '2026-06-01');
        RAISE EXCEPTION 'FAIL [m] Markt-Kurs in XAU angelegt';
    EXCEPTION WHEN foreign_key_violation THEN NULL;
    END;
    -- [g] currency_kind laesst sich nicht setzen
    BEGIN
        INSERT INTO finance.accounts (name, account_type, currency, currency_kind) VALUES ('__test__ x', 'cash', 'XAU', 'metal');
        RAISE EXCEPTION 'FAIL [g] currency_kind gesetzt';
    EXCEPTION WHEN generated_always THEN NULL;
    END;
    -- [e] freundliche Ablehnung vor jedem FK (kein RAISE -> kein Owner-Alarm)
    r := finance.fn_ensure_currency('XAU');
    IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%precious metal%' THEN
        RAISE EXCEPTION 'FAIL [e] fn_ensure_currency(XAU): %', r;
    END IF;
    -- [r] Kurs-Zeile EUR -> XAU bleibt erlaubt (fx_rates ohne Sperre)
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'XAU', 0.0003, DATE '2026-06-01', '__test__');
    -- [f] Fiat-Codes bleiben 'fiat': ein vom Feed gelernter Code wird nie zum Metall
    PERFORM finance.fn_ensure_currency('USD');
    IF (SELECT kind FROM finance.currencies WHERE code = 'USD') IS DISTINCT FROM 'fiat'
       OR finance.fn_is_metal('USD') OR NOT finance.fn_is_metal('XAU') OR finance.fn_is_metal('XYZ') THEN
        RAISE EXCEPTION 'FAIL [f] fn_is_metal/kind';
    END IF;
    RAISE NOTICE 'PASS test_currency_metal_guard [s Struktur, k Konto, p Position, m Markt-Kurs, g GENERATED, e Ablehnung, r fx_rates, f kind]';
END $$;
ROLLBACK;
