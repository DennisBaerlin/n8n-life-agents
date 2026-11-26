-- ============================================================
-- core.fn_render_plan_text(p_text, p_lang) — Anzeige-Haken fuer gespeicherte Plan-Texte
--   Jeder Thementext einer Karte laeuft bei der Anzeige hier durch (core.fn_render_prompt), damit ein Umbau der Darstellung
--   (z. B. Verweise statt Namen) eine Stelle hat. Liefert den Text unveraendert.
--   Tests: tests/db/core/test_fn_advisor_save_section_fields.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_render_plan_text(p_text text, p_lang text DEFAULT NULL)
RETURNS text
LANGUAGE sql STABLE
SET search_path = pg_catalog, pg_temp
AS $$
    SELECT p_text;
$$;
