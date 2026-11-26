-- ============================================================
-- test_fn_fx_rate — Kurs fuer jedes Waehrungspaar aus den EUR-Zeilen (finance.fn_fx_rate)
--   [9] EUR/JPY exakt die gespeicherte Zeile · [10] JPY/EUR = 1/Kurs · [11] USD/JPY gekreuzt = JPY-Kurs/USD-Kurs
--   [12] as_of = das aeltere der beiden Kurs-Daten · [13] fehlende Seite -> eine NULL-Zeile · [14] EUR/EUR = 1
--   Kleinbuchstaben werden normalisiert. BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE
    r record;
BEGIN
    PERFORM finance.fn_ensure_currency('JPY');
    PERFORM finance.fn_ensure_currency('USD');
    PERFORM finance.fn_ensure_currency('XTS');
    DELETE FROM finance.fx_rates WHERE quote_currency IN ('JPY', 'USD', 'XTS');
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES
        ('EUR', 'JPY', 1534.1234567891, CURRENT_DATE,     'test'),
        ('EUR', 'USD', 1.0834,          CURRENT_DATE - 3, 'test');

    -- [9] EUR/JPY exakt (kein 1/(1/rate)-Rauschen)
    SELECT * INTO r FROM finance.fn_fx_rate('EUR', 'JPY');
    IF r.rate IS DISTINCT FROM 1534.1234567891::numeric OR r.as_of IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FAIL [9] EUR/JPY: %', r;
    END IF;

    -- [10] JPY/EUR = 1/Kurs
    SELECT * INTO r FROM finance.fn_fx_rate('JPY', 'EUR');
    IF r.rate IS DISTINCT FROM 1 / 1534.1234567891::numeric OR r.as_of IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FAIL [10] JPY/EUR: %', r;
    END IF;

    -- [11] + [12] USD/JPY gekreuzt; as_of = aelteres Datum (USD von T-3)
    SELECT * INTO r FROM finance.fn_fx_rate('USD', 'JPY');
    IF r.rate IS DISTINCT FROM 1534.1234567891::numeric / 1.0834 THEN
        RAISE EXCEPTION 'FAIL [11] USD/JPY cross: %', r;
    END IF;
    IF r.as_of IS DISTINCT FROM CURRENT_DATE - 3 THEN
        RAISE EXCEPTION 'FAIL [12] USD/JPY as_of must be the older date: %', r;
    END IF;
    -- Kleinbuchstaben
    SELECT * INTO r FROM finance.fn_fx_rate('usd', 'jpy');
    IF r.rate IS DISTINCT FROM 1534.1234567891::numeric / 1.0834 THEN
        RAISE EXCEPTION 'FAIL lower-case pair: %', r;
    END IF;

    -- [13] fehlende Seite -> genau eine Zeile mit NULL
    IF (SELECT count(*) FROM finance.fn_fx_rate('EUR', 'XTS')) <> 1 THEN
        RAISE EXCEPTION 'FAIL [13] must return exactly one row';
    END IF;
    SELECT * INTO r FROM finance.fn_fx_rate('XTS', 'JPY');
    IF r.rate IS NOT NULL OR r.as_of IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [13] missing side must yield NULL: %', r;
    END IF;
    SELECT * INTO r FROM finance.fn_fx_rate('JPY', 'ZZZ');
    IF r.rate IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [13] unknown code must yield NULL: %', r;
    END IF;

    -- [14] EUR/EUR = 1 mit Stichtag
    SELECT * INTO r FROM finance.fn_fx_rate('EUR', 'EUR');
    IF r.rate IS DISTINCT FROM 1::numeric OR r.as_of IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FAIL [14] EUR/EUR: %', r;
    END IF;

    -- Stichtag in der Vergangenheit vor dem ersten JPY-Kurs -> zeitlich naechster
    SELECT * INTO r FROM finance.fn_fx_rate('EUR', 'JPY', CURRENT_DATE - 30);
    IF r.rate IS DISTINCT FROM 1534.1234567891::numeric OR r.as_of IS DISTINCT FROM CURRENT_DATE THEN
        RAISE EXCEPTION 'FAIL past as_of before first rate: %', r;
    END IF;

    -- fn_fx_rate_map nutzt dieselbe Kurs-Suche: eine Zeile nach dem heutigen Tag (UTC-Datum vor dem lokalen) gewinnt nicht
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'JPY', 9999, CURRENT_DATE + 1, 'test');
    IF (finance.fn_fx_rate_map()->>'JPY')::numeric IS DISTINCT FROM (SELECT f.rate FROM finance.fn_fx_rate('EUR', 'JPY') f)
       OR (finance.fn_fx_rate_map()->>'JPY')::numeric IS DISTINCT FROM 1534.1234567891::numeric
       OR (finance.fn_fx_rate_map()->>'EUR')::numeric IS DISTINCT FROM 1 THEN
        RAISE EXCEPTION 'FAIL fn_fx_rate_map must use the one lookup: %', finance.fn_fx_rate_map();
    END IF;

    RAISE NOTICE 'PASS test_fn_fx_rate [9 exakt, 10 invers, 11 gekreuzt, 12 aelteres Datum, 13 NULL, 14 EUR/EUR]';
END $$;
ROLLBACK;
