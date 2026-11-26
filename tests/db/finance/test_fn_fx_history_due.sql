-- ============================================================
-- test_fn_fx_history_due — fehlende EZB-Tage (finance.fn_fx_history_due): einmaliger Nachlauf + Ersatzquelle
--   faellig, solange keine EZB-Zeile existiert (Tages-Feed-Zeilen aendern nichts); Zeitraum = 5 Jahre bis heute
--   (bis = UTC-Datum: die Quelle kennt keinen spaeteren Tag); danach nur, wenn der Tages-Feed heute fehlt und kein Kurs von heute liegt. Rollen-Perspektive finance_rw (der FX-Cron).
--   BEGIN/ROLLBACK -> kein Residual-State.
-- ============================================================
BEGIN;
DO $$
DECLARE r jsonb; v_utc date := (now() AT TIME ZONE 'UTC')::date;
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
    -- Tages-Feed von heute (UTC) geholt: nach dem Nachlauf nichts mehr faellig
    UPDATE finance.fx_rates SET as_of = v_utc;
    PERFORM finance.fn_upsert_fx_rates('{"rows":[{"date":"2022-03-01","base":"EUR","quote":"USD","rate":1.12}]}'::jsonb);
    IF (finance.fn_fx_history_due()->>'due')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [nach dem Nachlauf, Feed aktuell -> nichts faellig]';
    END IF;
    -- Ersatzquelle: der Tages-Feed fehlt heute (juengster Stand vor 3 Tagen) -> die fehlenden Tage ab dem juengsten Kurs
    -- (gleich welcher Quelle) bis heute bei der EZB holen
    UPDATE finance.fx_rates SET as_of = v_utc - 3 WHERE source = finance.fn_fx_feed_source();
    r := finance.fn_fx_history_due();
    IF (r->>'due')::boolean IS DISTINCT FROM true OR (r->>'from')::date IS DISTINCT FROM v_utc - 2
       OR (r->>'to')::date IS DISTINCT FROM v_utc THEN
        RAISE EXCEPTION 'FAIL [Feed fehlt -> EZB ab juengstem Kurs + 1]: %', r;
    END IF;
    -- die EZB hat gestern geliefert -> ab heute
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'USD', 1.14, v_utc - 1, 'ecb');
    r := finance.fn_fx_history_due();
    IF (r->>'due')::boolean IS DISTINCT FROM true OR (r->>'from')::date IS DISTINCT FROM v_utc THEN
        RAISE EXCEPTION 'FAIL [EZB gestern -> ab heute]: %', r;
    END IF;
    -- der Kurs von heute liegt schon (EZB) -> nichts faellig, auch wenn der Tages-Feed fehlt
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'USD', 1.15, v_utc, 'ecb');
    IF (finance.fn_fx_history_due()->>'due')::boolean IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'FAIL [Kurs von heute da -> nichts faellig]';
    END IF;
    SET LOCAL ROLE finance_rw;
    r := finance.fn_fx_history_due();
    r := finance.fn_upsert_fx_rates('{"rows":[{"date":"2022-03-02","base":"EUR","quote":"USD","rate":1.13}]}'::jsonb);
    RESET ROLE;
    RAISE NOTICE 'PASS test_fn_fx_history_due [faellig ohne EZB-Zeile, 5 Jahre, Ersatz bei fehlendem Tages-Feed, finance_rw]';
END $$;
ROLLBACK;
