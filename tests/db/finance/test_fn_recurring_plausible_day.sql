-- ============================================================
-- test_fn_recurring_plausible_day -- Monatstag bei einem einzigen Termin (Kalendertage fest gewaehlt, Wochentage geprueft)
-- ============================================================
BEGIN;
DO $$
DECLARE
    c RECORD;
BEGIN
    FOR c IN SELECT * FROM (VALUES
        ('2026-03-15'::date, 15, 'normaler Tag'),
        ('2026-03-30'::date, -1, 'Tag 30 = Monatsletzter'),
        ('2026-01-29'::date, -1, 'Tag 29'),
        ('2026-02-27'::date, -1, 'Fr 27.02.2026, danach nur Sa/So bis Monatsende'),
        ('2026-02-26'::date, 26, 'Do 26.02.2026, Fr 27. ist Werktag'),
        ('2027-02-26'::date, -1, 'Fr 26.02.2027, danach nur Sa/So'),
        ('2026-02-28'::date, -1, 'Sa 28.02.2026 = Monatsletzter im Februar'),
        ('2028-02-28'::date, 28, 'Mo 28.02.2028, Schaltjahr: 29. ist Werktag'),
        ('2026-08-03'::date, 1, 'Mo 03.08.2026, 1./2. sind Sa/So'),
        ('2026-08-04'::date, 4, 'Di 04.08.2026'),
        ('2026-06-01'::date, 1, 'der 1.'),
        ('2026-07-28'::date, 28, 'Di 28.07.2026, danach Werktage')
    ) v(d, want, what) LOOP
        IF finance.fn_recurring_plausible_day(c.d) IS DISTINCT FROM c.want THEN
            RAISE EXCEPTION 'FAIL [%]: % -> % (erwartet %)', c.what, c.d, finance.fn_recurring_plausible_day(c.d), c.want;
        END IF;
    END LOOP;
    RAISE NOTICE 'PASS [fn_recurring_plausible_day]';
END $$;
ROLLBACK;
