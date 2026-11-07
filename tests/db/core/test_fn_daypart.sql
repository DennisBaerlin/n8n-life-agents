-- tests/db/core/test_fn_daypart.sql
-- core.fn_daypart(p_at): Tageszeit nach lokaler Stunde, halboffene Grenzen [5,11) [11,17) [17,22), Rest night;
-- Haushalts-Zeitzone = Sitzungs-Zeitzone (wie core.fn_today).
BEGIN;

SET LOCAL TimeZone = 'UTC';
DO $$
DECLARE
  c record;
BEGIN
  FOR c IN SELECT * FROM (VALUES
      ('2026-03-02 04:59:59+00', 'night'), ('2026-03-02 05:00:00+00', 'morning'), ('2026-03-02 10:59:59+00', 'morning'),
      ('2026-03-02 11:00:00+00', 'day'),   ('2026-03-02 16:59:59+00', 'day'),     ('2026-03-02 17:00:00+00', 'evening'),
      ('2026-03-02 21:59:59+00', 'evening'), ('2026-03-02 22:00:00+00', 'night'), ('2026-03-02 00:00:00+00', 'night')
    ) v(at, want)
  LOOP
    IF core.fn_daypart(c.at::timestamptz) IS DISTINCT FROM c.want THEN
      RAISE EXCEPTION 'FAIL fn_daypart [% -> %, erwartet %]', c.at, core.fn_daypart(c.at::timestamptz), c.want; END IF;
  END LOOP;
  IF core.fn_daypart() IS NULL THEN RAISE EXCEPTION 'FAIL fn_daypart [Standard now()]'; END IF;
END $$;

-- Zeitzone des Haushalts zaehlt: 04:30 UTC = 05:30 in Berlin (Winterzeit) -> morning
SET LOCAL TimeZone = 'Europe/Berlin';
DO $$
BEGIN
  IF core.fn_daypart('2026-01-15 04:30:00+00'::timestamptz) IS DISTINCT FROM 'morning' THEN
    RAISE EXCEPTION 'FAIL fn_daypart [Zeitzone: %]', core.fn_daypart('2026-01-15 04:30:00+00'::timestamptz); END IF;
  RAISE NOTICE 'PASS fn_daypart [Grenzen halboffen, Haushalts-Zeitzone]';
END $$;

ROLLBACK;
