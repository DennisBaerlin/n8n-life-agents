-- ============================================================
-- fn_interest_day_fraction (READ — Tageszaehl-Anteil eines Jahres je Konvention; DB rechnet, nie das LLM)
--   Liefert den Jahres-Bruchteil zwischen zwei Daten nach der gewaehlten day-count-Konvention. Reine
--   Datums-Arithmetik -> IMMUTABLE (in anderen fns/Ausdruecken nutzbar, kein Tabellenzugriff).
--     '30E/360' = deutsche kaufmaennische Methode: tage = 360*(y2-y1) + 30*(m2-m1) + (d2'-d1'), wobei
--                 Tag 31 -> 30 UND der letzte Februartag (28/29) -> 30; anteil = tage/360.
--     'ACT/365' = echte Kalendertage / 365 (Tagesgeld-Standard; im Schaltjahr ergibt ein volles Jahr >1).
--     'ACT/360' = echte Kalendertage / 360.
--   (ACT/ACT -> BACKLOG.) Quellen: zinsen-berechnen.de (deutsche/euro Zinsmethode), Wikipedia Day count
--   convention, OpenGamma Strata DayCounts.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_interest_day_fraction(
    p_from date, p_to date, p_convention text
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    WITH parts AS (
        SELECT
            EXTRACT(YEAR  FROM p_from)::int AS y1,
            EXTRACT(MONTH FROM p_from)::int AS m1,
            EXTRACT(DAY   FROM p_from)::int AS d1,
            EXTRACT(YEAR  FROM p_to)::int   AS y2,
            EXTRACT(MONTH FROM p_to)::int   AS m2,
            EXTRACT(DAY   FROM p_to)::int   AS d2,
            -- letzter Februartag? (Monat=2 UND der Folgetag liegt nicht mehr im Februar)
            (EXTRACT(MONTH FROM p_from)=2 AND EXTRACT(MONTH FROM p_from + 1)<>2) AS feb1,
            (EXTRACT(MONTH FROM p_to)=2   AND EXTRACT(MONTH FROM p_to + 1)<>2)   AS feb2
    ),
    adj AS (
        SELECT y1, m1, y2, m2,
            CASE WHEN d1 = 31 OR feb1 THEN 30 ELSE d1 END AS d1,
            CASE WHEN d2 = 31 OR feb2 THEN 30 ELSE d2 END AS d2
        FROM parts
    )
    SELECT CASE p_convention
        WHEN '30E/360' THEN (360*(y2-y1) + 30*(m2-m1) + (d2-d1))::numeric / 360
        WHEN 'ACT/365' THEN (p_to - p_from)::numeric / 365
        WHEN 'ACT/360' THEN (p_to - p_from)::numeric / 360
    END
    FROM adj;
$$;
