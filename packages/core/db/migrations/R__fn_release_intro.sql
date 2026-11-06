-- ============================================================
-- core.fn_release_intro(body) (read-only, IMMUTABLE — Update-Hinweis 2026-10-24)
--   Kurzfassung eines Releases fuer die Owner-Karte (Muster Home Assistant release_summary): der Einleitungsabsatz
--   der Tag-Nachricht = alles vor der ersten Leerzeile, '#'-Ueberschrift oder '---'-Linie (release.yml haengt den
--   Installations-Hinweis hinter '---' an). Zeilen werden mit Leerzeichen verbunden, Markdown-Hervorhebung ('**',
--   '__', Backticks) und Link-Syntax [text](url) -> text entfernt (die Karte geht als Plain-Text raus), Leerraum
--   zusammengefasst, auf 300 Zeichen gekuerzt (dann mit '…'). Beginnt der Text mit einer Ueberschrift -> ''.
--   Der Maintainer schreibt die Kurzfassung selbst (release.yml erzwingt sie) — kein LLM.
--   RUECKGABE: text (nie NULL)
--   Tests: tests/db/core/test_fn_release_card.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_release_intro(p_body text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_line  text;
    v_parts text[] := '{}';
    v_out   text;
BEGIN
    FOREACH v_line IN ARRAY regexp_split_to_array(replace(COALESCE(p_body, ''), E'\r', ''), E'\n') LOOP
        v_line := btrim(v_line);
        IF v_line = '' THEN
            EXIT WHEN cardinality(v_parts) > 0;   -- fuehrende Leerzeilen ueberspringen, die erste danach beendet
            CONTINUE;
        END IF;
        EXIT WHEN v_line ~ '^#' OR v_line ~ '^-{3,}$';
        v_parts := v_parts || v_line;
    END LOOP;

    v_out := array_to_string(v_parts, ' ');
    v_out := regexp_replace(v_out, '\[([^\]]*)\]\([^)]*\)', '\1', 'g');
    v_out := regexp_replace(v_out, '(\*\*|__|`)', '', 'g');
    v_out := btrim(regexp_replace(v_out, '\s+', ' ', 'g'));
    IF length(v_out) > 300 THEN
        v_out := rtrim(left(v_out, 299)) || '…';
    END IF;
    RETURN v_out;
END;
$$;
