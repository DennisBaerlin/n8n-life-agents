-- ============================================================
-- fn_recurring_plausible_day (IMMUTABLE) -- Monatstag eines Dauerauftrags, von dem nur EIN Termin gesehen wurde
--   Tag 29-31 -> -1 (Regel "der 30. = Monatsletzter"); bis zum Monatsende nur Wochenende (auch: Termin = Monatsletzter)
--   -> -1; seit Monatsbeginn nur Wochenende -> 1 (Buchung am Montag nach einem 1. am Wochenende); sonst der gebuchte Tag.
--   Feiertage zaehlen nicht (Fenster des Monats-Checks -5/+10 faengt sie). Ab zwei Terminen misst
--   fn_get_recurring_candidates den Tag selbst.
--   RUECKGABE: int in 1..28 | -1.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_plausible_day(p_date date)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN d >= 29 THEN -1
        WHEN NOT EXISTS (SELECT 1 FROM generate_series(p_date + 1, eom, interval '1 day') g
                         WHERE EXTRACT(ISODOW FROM g) < 6) THEN -1
        WHEN d > 1 AND NOT EXISTS (SELECT 1 FROM generate_series(som, p_date - 1, interval '1 day') g
                                   WHERE EXTRACT(ISODOW FROM g) < 6) THEN 1
        ELSE d END
    FROM (SELECT EXTRACT(DAY FROM p_date)::int AS d, date_trunc('month', p_date)::date AS som,
                 (date_trunc('month', p_date) + interval '1 month')::date - 1 AS eom) x;
$$;
