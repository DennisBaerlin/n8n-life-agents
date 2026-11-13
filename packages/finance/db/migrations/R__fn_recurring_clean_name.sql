-- ============================================================
-- fn_recurring_clean_name (IMMUTABLE) -- Name aus einem Kontoauszug fuer Vorschlag, Nachricht und Agent bereinigen
--   Wer Geld ueberweist, bestimmt Gegenpart-Text und Verwendungszweck mit; das Lese-Modell gibt daraus Namen (series,
--   counterparty) weiter. Darum: Links (http/https/www) raus, nur Buchstaben, Ziffern, Leerzeichen und & . - bleiben,
--   Leerraum zusammengefasst, hoechstens 40 Zeichen. Eingabe: p_name (text). Rueckgabe: text; leer/NULL -> NULL.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_clean_name(p_name text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT NULLIF(btrim(left(btrim(regexp_replace(regexp_replace(
               regexp_replace(COALESCE(p_name, ''), '(https?://|www\.)\S*', ' ', 'gi'),
               '[^[:alpha:][:digit:] &.-]', ' ', 'g'), '\s+', ' ', 'g')), 40)), '');
$$;
