-- ============================================================
-- core.fn_release_intro(body, lang) (read-only, IMMUTABLE) — Kurzfassung eines Releases fuer die Owner-Karte
--   Mit lang: steht im Text ein Marker '<!-- summary:<lang> … -->' mit nicht-leerem Inhalt, ist dessen Inhalt die
--   Kurzfassung. Sonst (lang NULL/ungueltig, kein oder leerer Marker, alter Release) der Einleitungsabsatz der
--   Tag-Nachricht = alles vor der ersten Leerzeile, '#'-Ueberschrift oder '---'-Linie (release.yml haengt den
--   Installations-Hinweis hinter '---' an); der Absatz ist englisch und gilt damit fuer 'en' und als Rueckfall.
--   Zeilen werden mit Leerzeichen verbunden, Markdown-Hervorhebung ('**', '__', Backticks) und Link-Syntax
--   [text](url) -> text entfernt (die Karte geht als Plain-Text raus), Leerraum zusammengefasst, auf 300 Zeichen
--   gekuerzt (dann mit '…'). Beginnt der Text mit einer Ueberschrift -> ''.
--   lang nur ^[a-z]{2,3}$ (Codes aus core.ui_languages), sonst Rueckfall — der Code geht in ein Regex-Muster.
--   Der Marker-Regex ist lazy ('\s*?'), sonst wird das ganze ARE gierig und verschluckt den Nachbar-Marker.
--   Der Maintainer schreibt die Kurzfassungen selbst (scripts/release_notes_check.ps1 erzwingt sie) — kein LLM.
--   RUECKGABE: text (nie NULL)
--   Tests: tests/db/core/test_fn_release_card.sql, scripts/dev/release_notes_check_test.ps1 (gleiche Faelle)
-- ============================================================
DROP FUNCTION IF EXISTS core.fn_release_intro(text);

CREATE OR REPLACE FUNCTION core.fn_release_intro(p_body text, p_lang text DEFAULT NULL)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE PARALLEL SAFE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_body  text := replace(COALESCE(p_body, ''), E'\r', '');
    v_mark  text[];
    v_line  text;
    v_parts text[] := '{}';
    v_out   text := '';
BEGIN
    IF p_lang ~ '^[a-z]{2,3}$' THEN
        v_mark := regexp_match(v_body, '<!--\s*?summary:' || p_lang || '\s+?(.*?)-->');
        IF v_mark IS NOT NULL THEN
            -- erst bereinigen: ein Marker, der danach leer ist, gilt als leer (Rueckfall)
            v_out := btrim(regexp_replace(regexp_replace(regexp_replace(v_mark[1],
                         '\[([^\]]*)\]\([^)]*\)', '\1', 'g'), '(\*\*|__|`)', '', 'g'), '\s+', ' ', 'g'));
        END IF;
    END IF;

    IF v_out = '' THEN
        FOREACH v_line IN ARRAY regexp_split_to_array(v_body, E'\n') LOOP
            v_line := btrim(v_line);
            IF v_line = '' THEN
                EXIT WHEN cardinality(v_parts) > 0;   -- fuehrende Leerzeilen ueberspringen, die erste danach beendet
                CONTINUE;
            END IF;
            EXIT WHEN v_line ~ '^#' OR v_line ~ '^-{3,}$';
            v_parts := v_parts || v_line;
        END LOOP;
        v_out := array_to_string(v_parts, ' ');
    END IF;

    v_out := regexp_replace(v_out, '\[([^\]]*)\]\([^)]*\)', '\1', 'g');
    v_out := regexp_replace(v_out, '(\*\*|__|`)', '', 'g');
    v_out := btrim(regexp_replace(v_out, '\s+', ' ', 'g'));
    IF length(v_out) > 300 THEN
        v_out := rtrim(left(v_out, 299)) || '…';
    END IF;
    RETURN v_out;
END;
$$;
