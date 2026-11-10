-- ============================================================
-- test_fn_fmt_money -- Geldbetrag fuer SQL-gerenderte Texte (gleiche Ausgabe wie Intl de-DE / en-GB / ko-KR)
-- ============================================================
BEGIN;
DO $$
DECLARE
    c RECORD;
BEGIN
    FOR c IN SELECT * FROM (VALUES
        (1234.5::numeric, 'EUR', 'de', '1.234,50 €'),
        (2400::numeric, 'EUR', 'en', '€2,400.00'),
        (9.99::numeric, 'EUR', 'ko', '€9.99'),
        (-12.3::numeric, 'EUR', 'de', '-12,30 €'),
        (-12.3::numeric, 'EUR', 'en', '-€12.30'),
        (1000000::numeric, 'USD', 'de', '1.000.000,00 USD'),
        (5::numeric, 'usd', 'en', 'USD 5.00'),
        (0.5::numeric, NULL, 'xx', '€0.50')
    ) v(a, cur, lang, want) LOOP
        IF core.fn_fmt_money(c.a, c.cur, c.lang) IS DISTINCT FROM c.want THEN
            RAISE EXCEPTION 'FAIL [% % %]: % (erwartet %)', c.a, c.cur, c.lang, core.fn_fmt_money(c.a, c.cur, c.lang), c.want;
        END IF;
    END LOOP;
    IF core.fn_fmt_money(NULL, 'EUR', 'de') IS NOT NULL THEN RAISE EXCEPTION 'FAIL [NULL]'; END IF;
    RAISE NOTICE 'PASS [core.fn_fmt_money]';
END $$;
ROLLBACK;
