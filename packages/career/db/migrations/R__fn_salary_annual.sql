-- ============================================================
-- career.fn_salary_annual (Gehalt aufs Jahr — render-at-fetch, nie gespeichert)
--   Ein Gehalt wird ROH mit seiner Einheit gespeichert (Betrag + period month|year + basis gross|net, WP3); das
--   LLM rechnet nie um. Jahreswert: month -> x 12 (Annahme 12 Gehaelter, so im Anzeigetext benannt), year -> Betrag;
--   ohne Einheit -> NULL (Bestand vor WP3: die Einheit ist unbekannt und wird nicht angenommen).
--   IMMUTABLE. Tests: tests/db/career/test_fn_salary_text.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_salary_annual(p_amount numeric, p_period text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE p_period WHEN 'month' THEN p_amount * 12 WHEN 'year' THEN p_amount END;
$$;
