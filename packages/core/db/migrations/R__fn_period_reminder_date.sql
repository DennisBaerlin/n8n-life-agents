-- ============================================================
-- core.fn_period_reminder_date (rein rechnend, READ-ONLY)
--   Rechnet eine ungenaue Zeitangabe in einen festen Erinnerungstag um, damit der Berater keinen Tag erfindet.
--   Formen: next_year, next_quarter (1. des zweiten Monats im Zeitraum), next_month (15. des naechsten Monats),
--   this_year (1. des naechsten Monats; liegt der im naechsten Jahr: NULL), in_<N>_months. Unbekannt: NULL.
--   p_on = Bezugstag (saved_at des Texts); NULL = heute, im Rumpf, weil ein DEFAULT auf core.fn_today das frische Apply braeche.
--   RUECKGABE: date oder NULL. Tests: tests/db/core/test_fn_period_reminder_date.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_period_reminder_date(p_period text, p_on date DEFAULT NULL)
RETURNS date LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_on date := COALESCE(p_on, core.fn_today());
    v_n  int;
    v_d  date;
BEGIN
    IF p_period = 'next_year' THEN
        RETURN make_date(extract(year FROM v_on)::int + 1, 2, 1);
    ELSIF p_period = 'next_quarter' THEN
        RETURN (date_trunc('quarter', v_on) + interval '4 months')::date;
    ELSIF p_period = 'next_month' THEN
        RETURN (date_trunc('month', v_on) + interval '1 month')::date + 14;
    ELSIF p_period = 'this_year' THEN
        v_d := (date_trunc('month', v_on) + interval '1 month')::date;
        RETURN CASE WHEN extract(year FROM v_d) = extract(year FROM v_on) THEN v_d END;
    ELSIF p_period ~ '^in_[0-9]{1,3}_months$' THEN
        v_n := (regexp_match(p_period, '^in_([0-9]+)_months$'))[1]::int;
        RETURN (v_on + make_interval(months => v_n))::date;
    END IF;
    RETURN NULL;
END;
$$;
