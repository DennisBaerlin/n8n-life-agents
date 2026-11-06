-- ============================================================
-- career.fn_partial_date (Roh-Datum in der Genauigkeit der Angabe)
--   Karriere-Fakten speichern Daten so genau, wie der Mensch sie nennt: "seit 2014" -> '2014', "seit September
--   2014" -> '2014-09', ein Tag -> '2014-09-15' (relative Angaben wie "-12 years" loest vorher core.fn_resolve_fact_dates
--   in genau diese Genauigkeit auf). Diese fn macht daraus den ersten Tag der Periode fuer Vergleiche/Ableitungen
--   (Validator: gueltig + nicht in der Zukunft; Renderer: "vor ~N Jahren"). Alles andere -> NULL.
--   IMMUTABLE. Tests: tests/db/career/test_fn_partial_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_partial_date(p_text text)
RETURNS date LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v text := btrim(COALESCE(p_text, ''));
BEGIN
    IF v ~ '^\d{4}$' THEN
        RETURN make_date(v::int, 1, 1);
    ELSIF v ~ '^\d{4}-\d{2}$' THEN
        RETURN make_date(left(v, 4)::int, right(v, 2)::int, 1);
    ELSIF v ~ '^\d{4}-\d{2}-\d{2}$' THEN
        RETURN v::date;
    END IF;
    RETURN NULL;
EXCEPTION WHEN OTHERS THEN
    RETURN NULL;   -- 2014-13 / 2014-02-30
END;
$$;
