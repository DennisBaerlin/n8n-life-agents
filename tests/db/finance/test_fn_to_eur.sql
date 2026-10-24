-- ============================================================
-- test_fn_to_eur — Multi-Waehrungs-Konversion + EUR-Roll-up in den Views
--   Deckt: EUR-Passthrough, KRW->EUR via fixem FX-Kurs, NULL-Betrag, fehlender Kurs -> NULL,
--   sowie die View-Integration (finance_account_overview.balance_eur konvertiert korrekt).
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_eur numeric;
    v_acc int;
BEGIN
    -- Test-Waehrung KRW (Baseline seedet nur EUR; hermetische DB -> self-seed, nicht Prod annehmen)
    INSERT INTO finance.currencies (code, minor_unit)
    VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;

    -- Fixer FX-Kurs als Fixture: 1 EUR = 1450 KRW.
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    VALUES ('EUR', 'KRW', 1450, CURRENT_DATE, 'test')
    ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

    -- 1. EUR-Passthrough
    IF finance.fn_to_eur(100.00, 'EUR') <> 100.00 THEN
        RAISE EXCEPTION 'FAIL: EUR passthrough expected 100.00, got %', finance.fn_to_eur(100.00, 'EUR');
    END IF;

    -- 2. KRW -> EUR: 1.450.000 KRW / 1450 = 1000.00 EUR
    v_eur := finance.fn_to_eur(1450000, 'KRW');
    IF v_eur <> 1000.00 THEN
        RAISE EXCEPTION 'FAIL: KRW conversion expected 1000.00, got %', v_eur;
    END IF;

    -- 3. NULL-Betrag -> NULL
    IF finance.fn_to_eur(NULL, 'KRW') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: NULL amount must yield NULL';
    END IF;

    -- 4. Fehlender Kurs -> NULL (sichtbar fehlend statt still falsch)
    INSERT INTO finance.currencies (code, minor_unit, symbol, name)
    VALUES ('USD', 2, '$', 'US Dollar') ON CONFLICT (code) DO NOTHING;
    IF finance.fn_to_eur(100, 'USD') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: missing FX rate must yield NULL, got %', finance.fn_to_eur(100, 'USD');
    END IF;

    -- 5. View-Integration: KRW-Konto -> finance_account_overview.balance_eur konvertiert.
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__test__ KRW Cash', 'cash', 'KRW', 'active') RETURNING id INTO v_acc;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_acc, 1450000, CURRENT_DATE, 'other');   -- Saldo via Trigger = 1.450.000 KRW
    SELECT balance_eur INTO v_eur FROM finance.account_overview WHERE id = v_acc;
    IF v_eur <> 1000.00 THEN
        RAISE EXCEPTION 'FAIL: account_overview.balance_eur expected 1000.00, got %', v_eur;
    END IF;

    RAISE NOTICE 'PASS test_fn_to_eur';
END $$;
ROLLBACK;
