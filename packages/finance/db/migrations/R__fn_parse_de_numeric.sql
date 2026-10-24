-- ============================================================
-- fn_parse_de_numeric (IMMUTABLE — deutsche/plain Zahl-Strings -> kanonischer Zahl-Text)
--   Gibt den Roh-String als plain numerischen Text zurueck ('.' = Dezimalpunkt, keine
--   Tausender), damit der nachgelagerte ::numeric-Cast NIE an deutscher Schreibweise scheitert
--   (Review LM2: User pastet "4.200,50" -> Cast failte -> Fehler bei jedem realistischen Betrag).
--   p_thousands_dot = TRUE NUR fuer Geldbetraege (dort ist "4.200" ein deutscher Tausender);
--   FALSE fuer Stueckzahlen/Kurse/Zinssaetze (dort ist "0.125" BTC oder "3.125" % ein Dezimalwert —
--   Audit-Fund 2026-10-21: die Tausender-Heuristik machte daraus 125 bzw. 3125).
--   Regel (deterministisch, dokumentiert):
--     * Whitespace + Waehrungssymbole (€, EUR, $) entfernt
--     * Vorzeichen: fuehrendes '-', '(..)', NACHGESTELLTES '-' ("1.234,56-", Kontoauszug-Soll) und das
--       Unicode-Minus U+2212 gelten als negativ
--     * beide Separatoren ('.' und ',') vorhanden -> der LETZTE ist das Dezimaltrennzeichen;
--       der andere wird als Tausendertrenner verworfen ("4.200,50"->4200.50; "4,200.50"->4200.50)
--     * nur ',' -> deutsches Dezimalkomma ("4200,50"->4200.50); GELD mit genau 3 Ziffern nach dem Komma ("1,234")
--       ist mehrdeutig -> Rohwert (Cast-Fehler = Rueckfrage)
--     * Exponent ("1e-7") -> unveraendert (der Cast liest ihn korrekt)
--     * nur '.' und p_thousands_dot: EIN Punkt mit GENAU 3 Folgeziffern bis Stringende -> deutscher
--       Tausender ("4.200"->4200); mehrere Punkte ohne Komma -> Tausender ("1.234.567"->1234567);
--       sonst Dezimalpunkt ("4.2"->4.2, "4.50"->4.50)
--     * nur '.' ohne p_thousands_dot: immer Dezimalpunkt ("0.125"->0.125)
--     * keiner -> unveraendert
--   RESIDUUM (dokumentiert, akzeptiert): ein als Dezimal gemeinter GELD-Betrag "4.200" (=4.2) wird als
--   Tausender 4200 gelesen — in Betraegen mit 2 Nachkommastellen kommt das nicht vor. JSON-Zahlen
--   erreichen diese fn gar nicht (fn_import_normalize_payload parst nur Strings).
--   NULL/leer/nicht-parsebar -> Rohwert unveraendert zurueck (der ::numeric-Cast meldet den
--   Fehler dann als freundlichen Row-Fehler).
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_parse_de_numeric(text);   -- Vorgaenger-Signatur (1-arg) -> 2-arg

CREATE OR REPLACE FUNCTION finance.fn_parse_de_numeric(p_raw text, p_thousands_dot boolean)
RETURNS text LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v TEXT := p_raw;
    v_neg BOOLEAN := FALSE;
BEGIN
    IF v IS NULL THEN RETURN NULL; END IF;
    v := trim(replace(v, '−', '-'));                         -- Unicode-Minus U+2212 -> ASCII
    IF v = '' THEN RETURN v; END IF;

    -- Waehrungssymbole/Codes + Whitespace raus
    v := regexp_replace(v, '(?i)\s|€|\$|eur|usd|chf|krw|₩', '', 'g');
    -- Exponent-Schreibweise ("1e-7", "2E3 €"; NACH dem Abstreifen von Einheit/Waehrung): der ::numeric-Cast liest sie
    -- korrekt -> unveraendert durch (Rundungs-Paket 2026-10-23: vorher Buchstaben/Minus gestrichen, "1e-7" -> "17").
    -- Andere Einheiten ("1e-7 BTC") bleiben Buchstaben -> Rohwert, der Cast meldet den Zeilenfehler (nie still falsch).
    IF v ~ '^[+-]?[0-9]*\.?[0-9]+[eE][+-]?[0-9]+$' THEN RETURN v; END IF;
    IF v ~ '[0-9.,][eE][+-]?[0-9]' AND v ~ '[A-Za-z]{2,}' THEN RETURN p_raw; END IF;
    IF v ~ '^-' OR v ~ '^\(' OR v ~ '-$' THEN v_neg := TRUE; END IF;   -- fuehrend/(..)/nachgestellt
    v := regexp_replace(v, '[^0-9.,]', '', 'g');           -- nur Ziffern + Separatoren
    IF v = '' THEN RETURN p_raw; END IF;

    IF position('.' IN v) > 0 AND position(',' IN v) > 0 THEN
        -- beide: der LETZTE Separator ist das Dezimalzeichen
        IF position('.' IN reverse(v)) < position(',' IN reverse(v)) THEN
            v := replace(v, ',', '');          -- '.' ist Dezimal -> ',' (Tausender) raus
        ELSE
            v := replace(v, '.', '');           -- ',' ist Dezimal
            v := replace(v, ',', '.');
        END IF;
    ELSIF position(',' IN v) > 0 THEN
        -- GELD mit genau einem Komma + 3 Folgeziffern ("1,234"): engl. Tausender (1234) oder dt. Dezimal (1,234)?
        -- Geldbetraege haben 2 Nachkommastellen -> mehrdeutig: Rohwert zurueck, der Cast meldet den freundlichen
        -- Zeilenfehler (nachfragen statt raten; Rundungs-Paket 2026-10-23). Stueck/Kurs: eindeutig dezimal.
        IF p_thousands_dot AND v ~ '^[0-9]+,[0-9]{3}$' THEN RETURN p_raw; END IF;
        v := replace(v, ',', '.');              -- nur Komma = deutsches Dezimal
    ELSIF position('.' IN v) > 0 AND p_thousands_dot THEN
        IF v ~ '^[0-9]+\.[0-9]{3}$' OR (length(v) - length(replace(v, '.', ''))) > 1 THEN
            v := replace(v, '.', '');           -- Tausender-Punkt(e)
        END IF;                                  -- sonst: Dezimalpunkt, unveraendert
    END IF;

    IF v_neg AND v <> '' AND left(v,1) <> '-' THEN v := '-' || v; END IF;
    RETURN v;
END;
$$;
