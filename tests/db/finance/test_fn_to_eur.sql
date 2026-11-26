-- ============================================================
-- test_fn_to_eur — Multi-Waehrungs-Konversion + EUR-Roll-up in den Views
--   Deckt: EUR-Passthrough, CLP->EUR via fixem FX-Kurs, NULL-Betrag, fehlender Kurs -> NULL,
--   sowie die View-Integration (finance_account_overview.balance_eur konvertiert korrekt);
--   Kurs-Suche fn_fx_eur_row: Stichtag vor dem ersten Kurs -> aeltester Kurs, dazwischen -> juengster <= Stichtag.
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_eur numeric;
    v_acc int;
BEGIN
    -- Test-Waehrung CLP (Baseline seedet nur EUR; hermetische DB -> self-seed, nicht Prod annehmen)
    INSERT INTO finance.currencies (code, minor_unit)
    VALUES ('CLP', 0) ON CONFLICT (code) DO NOTHING;

    -- Fixer FX-Kurs als Fixture: 1 EUR = 1450 CLP.
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    VALUES ('EUR', 'CLP', 1450, CURRENT_DATE, 'test')
    ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

    -- 1. EUR-Passthrough
    IF finance.fn_to_eur(100.00, 'EUR') <> 100.00 THEN
        RAISE EXCEPTION 'FAIL: EUR passthrough expected 100.00, got %', finance.fn_to_eur(100.00, 'EUR');
    END IF;

    -- 2. CLP -> EUR: 1.450.000 CLP / 1450 = 1000.00 EUR
    v_eur := finance.fn_to_eur(1450000, 'CLP');
    IF v_eur <> 1000.00 THEN
        RAISE EXCEPTION 'FAIL: CLP conversion expected 1000.00, got %', v_eur;
    END IF;

    -- 3. NULL-Betrag -> NULL
    IF finance.fn_to_eur(NULL, 'CLP') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: NULL amount must yield NULL';
    END IF;

    -- 4. Fehlender Kurs -> NULL (sichtbar fehlend statt still falsch)
    INSERT INTO finance.currencies (code, minor_unit, symbol, name)
    VALUES ('USD', 2, '$', 'US Dollar') ON CONFLICT (code) DO NOTHING;
    IF finance.fn_to_eur(100, 'USD') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL: missing FX rate must yield NULL, got %', finance.fn_to_eur(100, 'USD');
    END IF;

    -- 5. View-Integration: CLP-Konto -> finance_account_overview.balance_eur konvertiert.
    INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__test__ CLP Cash', 'cash', 'CLP', 'active') RETURNING id INTO v_acc;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_acc, 1450000, CURRENT_DATE, 'other');   -- Saldo via Trigger = 1.450.000 CLP
    SELECT balance_eur INTO v_eur FROM finance.account_overview WHERE id = v_acc;
    IF v_eur <> 1000.00 THEN
        RAISE EXCEPTION 'FAIL: account_overview.balance_eur expected 1000.00, got %', v_eur;
    END IF;

    RAISE NOTICE 'PASS test_fn_to_eur';
END $$;

-- ============================================================
-- Rueckfall vor dem ersten Kurs: juengster Kurs <= Stichtag, sonst der AELTESTE Kurs danach
-- (zeitlich naechster, Muster Odoo), nicht der neueste. fn_to_eur_unrounded setzt auf fn_fx_eur_row auf.
-- ============================================================
DO $$
DECLARE
    v_row record;
BEGIN
    PERFORM finance.fn_ensure_currency('JPY');
    DELETE FROM finance.fx_rates WHERE quote_currency = 'JPY';
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES
        ('EUR', 'JPY', 1000, CURRENT_DATE - 10, 'test'),
        ('EUR', 'JPY', 1500, CURRENT_DATE,      'test');

    -- [6] Stichtag vor dem ersten Kurs -> aeltester Kurs (T-10), nicht der neueste (T)
    IF finance.fn_to_eur_unrounded(1000, 'JPY', CURRENT_DATE - 20) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FAIL [6] before first rate: expected 1 (rate of T-10), got %',
            finance.fn_to_eur_unrounded(1000, 'JPY', CURRENT_DATE - 20);
    END IF;
    IF finance.fn_to_eur(1000, 'JPY', CURRENT_DATE - 20) IS DISTINCT FROM 1.00 THEN
        RAISE EXCEPTION 'FAIL [6] fn_to_eur before first rate: got %', finance.fn_to_eur(1000, 'JPY', CURRENT_DATE - 20);
    END IF;
    -- [7] Stichtag zwischen zwei Kursen -> juengster <= Stichtag
    IF finance.fn_to_eur_unrounded(1000, 'JPY', CURRENT_DATE - 5) IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FAIL [7] between rates: got %', finance.fn_to_eur_unrounded(1000, 'JPY', CURRENT_DATE - 5);
    END IF;
    IF finance.fn_to_eur_unrounded(1500, 'JPY') IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FAIL [7] today: got %', finance.fn_to_eur_unrounded(1500, 'JPY');
    END IF;
    -- [8b] eine Kurs-Suche: fn_fx_eur_row liefert Kurs + Datum, fn_to_eur_unrounded rechnet mit genau diesem Kurs
    FOR v_row IN SELECT d FROM unnest(ARRAY[CURRENT_DATE - 20, CURRENT_DATE - 10, CURRENT_DATE - 5, CURRENT_DATE, CURRENT_DATE + 3]) d LOOP
        IF finance.fn_to_eur_unrounded(1, 'JPY', v_row.d)
           IS DISTINCT FROM 1 / (SELECT r.rate FROM finance.fn_fx_eur_row('JPY', v_row.d) r) THEN
            RAISE EXCEPTION 'FAIL [8b] drift fn_to_eur_unrounded vs fn_fx_eur_row at %', v_row.d;
        END IF;
    END LOOP;
    SELECT * INTO v_row FROM finance.fn_fx_eur_row('JPY', CURRENT_DATE - 20);
    IF v_row.rate IS DISTINCT FROM 1000::numeric OR v_row.as_of IS DISTINCT FROM CURRENT_DATE - 10 THEN
        RAISE EXCEPTION 'FAIL [8b] fn_fx_eur_row before first: %', v_row;
    END IF;
    SELECT * INTO v_row FROM finance.fn_fx_eur_row('JPY', CURRENT_DATE - 5);
    IF v_row.rate IS DISTINCT FROM 1000::numeric OR v_row.as_of IS DISTINCT FROM CURRENT_DATE - 10 THEN
        RAISE EXCEPTION 'FAIL [8b] fn_fx_eur_row between: %', v_row;
    END IF;
    -- Waehrung ohne jede Zeile -> keine Zeile (fn_to_eur -> NULL)
    PERFORM finance.fn_ensure_currency('XTS');
    IF EXISTS (SELECT 1 FROM finance.fn_fx_eur_row('XTS', CURRENT_DATE)) THEN
        RAISE EXCEPTION 'FAIL fn_fx_eur_row without any rate must return no row';
    END IF;
    -- EUR = Basis: Kurs 1 ohne Kurs-Datum
    SELECT * INTO v_row FROM finance.fn_fx_eur_row('EUR', CURRENT_DATE);
    IF v_row.rate IS DISTINCT FROM 1::numeric OR v_row.as_of IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL fn_fx_eur_row EUR: %', v_row;
    END IF;

    RAISE NOTICE 'PASS test_fn_to_eur [6 vor erstem Kurs = aeltester, 7 dazwischen, 8b eine Kurs-Suche]';
END $$;
ROLLBACK;
