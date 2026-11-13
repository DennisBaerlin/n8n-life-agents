-- ============================================================
-- fn_parse_small_int (READ HELPER, IMMUTABLE) -- eine kleine Ganzzahl aus einer Nutzer-/LLM-Eingabe
--   Die eine Adresse fuer das Einlesen der Zins-Kadenzfelder (interval, Gutschrift-Tag, Arrears-Tag): fn_account_interest_defaults
--   (Karte = Write) liest damit, fn_create_account lehnt einen genannten, aber unlesbaren Wert damit ab -> geprueft wird,
--   was gespeichert wird (kein Auseinanderlaufen von Check und Vorschlag, z. B. bei "+3").
--   Eingabe: p_text. Rueckgabe: int oder NULL.
--   Erlaubt: optionales Vorzeichen, 1-4 Ziffern, Leerraum aussen ("3", "+3", " -1 "); sonst NULL (auch "3.0", "last",
--   "99999" -> kein Cast-Ueberlauf). NULL/leer -> NULL.
--   Tests: tests/db/finance/test_fn_account_interest_defaults.sql, tests/db/finance/test_fn_create_account.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_parse_small_int(p_text text)
RETURNS int LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_text ~ '^\s*[+-]?\d{1,4}\s*$' THEN btrim(p_text)::int END;
$$;
