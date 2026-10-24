-- ============================================================
-- fn_name_matches (NAMENS-VERGLEICH DER RESOLVER)
--   Die EINE Vergleichsregel aller fn_resolve_*-Namensaufloesungen ("erst exakt, nur bei 0 Treffern ohne
--   Gross-/Kleinschreibung", Paket DB-ist-das-Gesetz S3):
--     p_exact = TRUE  -> p_candidate = p_name (wie bisher)
--     p_exact = FALSE -> lower(btrim()) beider Seiten gleich (kein Pattern: '_'/'%' sind normale Zeichen)
--   Die Resolver rufen erst mit TRUE und nur bei 0 Treffern mit FALSE -> Bestandspaare, die sich nur in der
--   Schreibweise unterscheiden, bleiben bei exakter Eingabe eindeutig.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_name_matches(p_candidate text, p_name text, p_exact boolean)
RETURNS boolean
LANGUAGE sql
IMMUTABLE
AS $$
    SELECT CASE WHEN p_exact THEN p_candidate = p_name
                ELSE lower(btrim(p_candidate)) = lower(btrim(p_name)) END;
$$;
