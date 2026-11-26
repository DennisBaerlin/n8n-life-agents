-- ============================================================
-- test_fn_fx_history_due — einmaliger EZB-Nachlauf der Kurs-Geschichte (finance.fn_fx_history_due)
--   faellig, solange keine EZB-Zeile existiert (Tages-Feed-Zeilen aendern nichts); Zeitraum = 5 Jahre bis heute
--   (bis = UTC-Datum: die Quelle kennt keinen spaeteren Tag); nach dem Nachlauf nie wieder. Rollen-Perspektive finance_rw (der FX-Cron).
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE r jsonb;
BEGIN
    DELETE FROM finance.fx_rates;
    PERFORM finance.fn_ensure_currency('USD');
    r := finance.fn_fx_history_due();
    IF (r->>'due')::boolean IS DISTINCT FROM true
       OR (r->>'from')::date IS DISTINCT FROM (core.fn_today() - interval '5 years')::date
       OR (r->>'to')::date IS DISTINCT FROM (now() AT TIME ZONE 'UTC')::date THEN
        RAISE EXCEPTION 'FAIL [leer -> faellig, 5 Jahre]: %', r;
    END IF;
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
    VALUES ('EUR', 'USD', 1.1, core.fn_today(), finance.fn_fx_feed_source());
    IF finance.fn_fx_history_source() = finance.fn_fx_feed_source() THEN
        RAISE EXCEPTION 'FAIL [Quellen muessen verschieden sein]';
    END IF;
    IF (finance.fn_fx_history_due()->>'due')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [nur Tages-Feed -> weiter faellig]';
    END IF;
    PERFORM finance.fn_upsert_fx_rates('{"rows":[{"date":"2022-03-01","base":"EUR","quote":"USD","rate":1.12}]}'::jsonb);
    IF (finance.fn_fx_history_due()->>'due')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [nach dem Nachlauf -> nie wieder]';
    END IF;
    SET LOCAL ROLE finance_rw;
    r := finance.fn_fx_history_due();
    r := finance.fn_upsert_fx_rates('{"rows":[{"date":"2022-03-02","base":"EUR","quote":"USD","rate":1.13}]}'::jsonb);
    RESET ROLE;
    RAISE NOTICE 'PASS test_fn_fx_history_due [faellig ohne EZB-Zeile, 5 Jahre, danach nie, finance_rw]';
END $$;
ROLLBACK;
