-- ============================================================
-- fn_holder_tokens (READ, IMMUTABLE) -- Namens-Tokens eines Bank-Drucks bzw. Haushaltsnamens (fn_match_household_holder)
--   Kleinschrift, ss fuer ß, Umlaute je p_variant: 1 = ae/oe/ue ("MUELLER"), 2 = a/o/u ("MULLER"); gaengige Akzente
--   ohne Akzent (é -> e). Alles ausser a-z trennt. Weg fallen Tokens unter 2 Zeichen (Initialen) und Fuellwoerter
--   (und, and, u, oder, or, herr, frau, dr, prof). RUECKGABE: text[] ohne Dubletten, sortiert ('{}' bei NULL/leer).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_holder_tokens(p text, p_variant int)
RETURNS text[] LANGUAGE sql IMMUTABLE AS $$
    SELECT COALESCE(array_agg(DISTINCT t ORDER BY t), '{}')
    FROM regexp_split_to_table(
             regexp_replace(
                 translate(
                     replace(replace(replace(replace(lower(COALESCE(p, '')), 'ß', 'ss'),
                         'ä', CASE WHEN p_variant = 1 THEN 'ae' ELSE 'a' END),
                         'ö', CASE WHEN p_variant = 1 THEN 'oe' ELSE 'o' END),
                         'ü', CASE WHEN p_variant = 1 THEN 'ue' ELSE 'u' END),
                     'áàâãåéèêëíìîïóòôõúùûçñ', 'aaaaaeeeeiiiiooooouuucn'),
                 '[^a-z]+', ' ', 'g'),
             '\s+') AS t
    WHERE length(t) >= 2 AND t NOT IN ('und', 'and', 'oder', 'or', 'herr', 'frau', 'dr', 'prof');
$$;
