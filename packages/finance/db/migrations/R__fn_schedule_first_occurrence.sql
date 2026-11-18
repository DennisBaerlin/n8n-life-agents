-- ============================================================
-- fn_schedule_first_occurrence (READ, IMMUTABLE) — erster Termin eines Rhythmus
--   Der erste Faelligkeitstermin >= p_anchor im einen Raster finance.fn_schedule_occurrences (Monat: fester Tag aus p_dom
--   inkl. -1 Monatsletzter / -2 vorletzter Tag, bzw. feste Monatstage p_days; Tag/Woche/Jahr: der Anker selbst).
--   Write-fns verankern damit ein first_payment_date, das nicht zum Monatstag passt ("today" + Zahltag 1 -> naechster 1.),
--   damit Karte, gespeicherter Anker und Erinnerungen dasselbe Datum zeigen.
--   Eingabe: p_anchor date, p_interval int, p_unit finance.schedule_unit, p_dom smallint, p_days smallint[] (Rhythmus-Felder
--   wie fn_schedule_occurrences). RUECKGABE date; p_anchor NULL -> NULL; kein Termin im Fenster (Anker + eine Periode + 31 Tage) -> p_anchor.
--   Mehrmonats-/Jahresrhythmus mit festem Tag (p_dom oder p_days): der naechste Tag ab Anker, auch bei Intervall > 1 und Einheit
--   Jahr. Grenze: das Jahresraster ignoriert den Tag (Anker + k Jahre), ein Tag -1 faellt dort im Folgejahr auf den
--   Ankertag (28.02. -> 28.02.).
--   Tests: tests/db/finance/test_fn_create_recurring_payment_anchor.sql, test_prop_first_due_multi_month.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_schedule_first_occurrence(
    p_anchor date, p_interval int, p_unit finance.schedule_unit, p_dom smallint, p_days smallint[]
) RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(
        (SELECT min(o.d) FROM finance.fn_schedule_occurrences(
             p_anchor,
             -- Mehrmonats-/Jahresrhythmus mit festem Tag: der erste Termin ist der naechste solche Tag ab Anker (1-Monats-Raster),
             -- nie ein ganzes Intervall spaeter; der gespeicherte Anker ist dann schon der erste Termin, der Rhythmus laeuft von dort.
             CASE WHEN p_unit IN ('month', 'year') AND (p_dom IS NOT NULL OR p_days IS NOT NULL) THEN 1 ELSE p_interval END,
             CASE WHEN p_unit IN ('month', 'year') AND (p_dom IS NOT NULL OR p_days IS NOT NULL) THEN 'month'::finance.schedule_unit ELSE p_unit END,
             p_dom, p_days, p_anchor,
             (p_anchor + CASE p_unit WHEN 'day'  THEN make_interval(days => GREATEST(COALESCE(p_interval, 1), 1))
                                     WHEN 'week' THEN make_interval(days => 7 * GREATEST(COALESCE(p_interval, 1), 1))
                                     WHEN 'year' THEN make_interval(years => GREATEST(COALESCE(p_interval, 1), 1))
                                     ELSE make_interval(months => GREATEST(COALESCE(p_interval, 1), 1)) END
                         + interval '31 days')::date) AS o(d)),
        p_anchor);
$$;
