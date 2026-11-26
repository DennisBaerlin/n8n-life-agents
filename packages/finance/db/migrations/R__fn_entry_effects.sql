-- ============================================================
-- fn_entry_effects (READ, STABLE) -- Folge-Zeile der Eintrags-Liste: wie viele Konten ein offener Eintrag noch verfaelscht
--   Gedacht fuer das Registry-Feld core.advisors.entry_effects_fn (Signatur (text domain) -> jsonb) und die Kartenzeile
--   core.handoff.effect {n} der Liste ("solange das fehlt, stimmt meine Vorschau fuer n Konten nicht"). Gezaehlt werden die
--   Konten mit einem Hinweis der Klasse entry aus finance.fn_advisor_hints (nicht dringend, eine offene Vormerkung nennt das
--   Konto); dringende Hinweise kommen als eigene Frage und zaehlen hier nicht. Abgeleitet bei jedem Lesen, nichts gespeichert:
--   mit dem Eintragen oder Streichen faellt das Konto von allein heraus.
--   Eingabe p_domain (Domaene der Vormerkungen). Rueckgabe {accounts:int}; 0 = keine Zeile.
--   Tests: tests/db/finance/test_fn_entry_effects.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_entry_effects(p_domain text)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN jsonb_build_object('accounts',
        (SELECT count(DISTINCT e->>'account')::int FROM jsonb_array_elements(finance.fn_advisor_hints(p_domain)) e
          WHERE e->>'class' = 'entry'));
END;
$$;
