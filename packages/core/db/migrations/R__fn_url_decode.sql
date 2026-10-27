-- ============================================================
-- core.fn_url_decode (rein) — Prozent-Dekodierung eines application/x-www-form-urlencoded-Teils
--   '+' -> Leerzeichen, %XX -> Byte; die Bytes werden als UTF-8 gelesen (mehrbytige Zeichen wie Hangul oder
--   Umlaute kommen als %EC%A7%80 bzw. %C3%BC). Ein einzelnes '%' ohne zwei Hex-Ziffern bleibt woertlich.
--   Ungueltiges UTF-8 -> RAISE (der Aufrufer faengt es ab, core.fn_app_verify_init_data -> malformed).
--   IMMUTABLE, liest nichts -> kein DEFINER/Grant.
--   RUECKGABE: text (NULL -> NULL, '' -> '')
--   Tests: tests/db/core/test_fn_app_verify_init_data.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_url_decode(p text)
RETURNS text LANGUAGE sql IMMUTABLE STRICT
SET search_path = pg_catalog
AS $$
    SELECT convert_from(COALESCE(string_agg(
               CASE WHEN m[1] IS NOT NULL THEN decode(m[1], 'hex') ELSE convert_to(m[2], 'UTF8') END,
               ''::bytea ORDER BY o), ''::bytea), 'UTF8')
      FROM regexp_matches(replace(p, '+', ' '), '%([0-9A-Fa-f]{2})|([^%]+|%)', 'g') WITH ORDINALITY AS t(m, o);
$$;
