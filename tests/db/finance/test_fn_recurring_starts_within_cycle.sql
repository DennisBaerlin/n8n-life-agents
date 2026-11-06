-- tests/db/finance/test_fn_recurring_starts_within_cycle.sql
-- finance.fn_recurring_starts_within_cycle(valid_from, interval, unit, on): die eine Regel „zaehlt schon regulaer“.
-- Fenster = heute + GREATEST(ein Rhythmus, 1 Monat) + 3 Tage; Tage und Wochen bekommen mindestens einen Monat, die drei
-- Tage decken den laengsten Abstand zweier Monatsenden (28.2. -> 31.3.). Gestartetes zaehlt immer.
BEGIN;
DO $$
DECLARE
  d DATE := DATE '2026-11-02';
BEGIN
  -- Rhythmus-Grenzen: letzter Tag im Fenster zaehlt, der Tag danach nicht
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2026-12-05', 1, 'month', d) THEN RAISE EXCEPTION 'FAIL [month] +1 Monat +3 Tage zaehlt'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2026-12-06', 1, 'month', d) THEN RAISE EXCEPTION 'FAIL [month] +1 Monat +4 Tage zaehlt nicht'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2027-01-05', 2, 'month', d) THEN RAISE EXCEPTION 'FAIL [month/2] drin'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2027-01-06', 2, 'month', d) THEN RAISE EXCEPTION 'FAIL [month/2] draussen'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2027-02-05', 3, 'month', d) THEN RAISE EXCEPTION 'FAIL [month/3] drin'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2027-02-06', 3, 'month', d) THEN RAISE EXCEPTION 'FAIL [month/3] draussen'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2027-11-05', 1, 'year', d) THEN RAISE EXCEPTION 'FAIL [year] drin'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2027-11-06', 1, 'year', d) THEN RAISE EXCEPTION 'FAIL [year] draussen'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2028-11-05', 2, 'year', d) THEN RAISE EXCEPTION 'FAIL [year/2] drin'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2028-11-06', 2, 'year', d) THEN RAISE EXCEPTION 'FAIL [year/2] draussen'; END IF;

  -- Tage und Wochen: mindestens ein Monat (woechentlich heisst bei festen Monatstagen „month“ und wird gleich behandelt)
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2026-12-05', 1, 'week', d) THEN RAISE EXCEPTION 'FAIL [week] mindestens ein Monat'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2026-12-06', 1, 'week', d) THEN RAISE EXCEPTION 'FAIL [week] draussen'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2026-12-05', 1, 'day', d) THEN RAISE EXCEPTION 'FAIL [day] mindestens ein Monat'; END IF;
  IF finance.fn_recurring_starts_within_cycle(DATE '2026-12-06', 1, 'day', d) THEN RAISE EXCEPTION 'FAIL [day] draussen'; END IF;
  -- laenger als ein Monat bleibt der eigene Rhythmus
  IF NOT finance.fn_recurring_starts_within_cycle(d + 63, 9, 'week', d) THEN RAISE EXCEPTION 'FAIL [week/9] eigener Rhythmus'; END IF;

  -- Monatsenden: der naechste Monatsletzte faellt immer ins Fenster
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2026-05-31', 1, 'month', DATE '2026-04-30') THEN RAISE EXCEPTION 'FAIL [Monatsende] 30.4. -> 31.5.'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2027-03-31', 1, 'month', DATE '2027-02-28') THEN RAISE EXCEPTION 'FAIL [Monatsende] 28.2. -> 31.3.'; END IF;

  -- Heute oder frueher gestartet zaehlt immer; fehlendes Intervall = 1
  IF NOT finance.fn_recurring_starts_within_cycle(d, 1, 'month', d) THEN RAISE EXCEPTION 'FAIL [heute]'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(d - 400, 1, 'month', d) THEN RAISE EXCEPTION 'FAIL [frueher]'; END IF;
  IF NOT finance.fn_recurring_starts_within_cycle(DATE '2026-12-05', NULL, 'month', d) THEN RAISE EXCEPTION 'FAIL [Intervall NULL]'; END IF;

  RAISE NOTICE 'PASS fn_recurring_starts_within_cycle: Rhythmus-Grenzen, mindestens ein Monat, Monatsenden, gestartet';
END $$;
ROLLBACK;
