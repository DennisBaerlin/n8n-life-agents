-- ============================================================
-- fn_ui_money (READ-ONLY, IMMUTABLE — typisierter Wert fester Texte)
--   Eingabe: p_value numeric, p_currency text (Default 'EUR'), p_sign boolean, p_whole boolean.
--   Betrag als typisierter Rohwert {kind:'money', value, currency} fuer core.fn_ui_tpl-Parameter; der Workflow
--   formatiert per Intl im Locale des Empfaengers (nie to_char: das Format hinge an lc_numeric der Session).
--   value auf 2 Stellen gerundet (Anzeige-Wert; gerechnet ist vorher), NULL -> null (Renderer: '—').
--   p_sign = true -> zusaetzlich sign:true (Renderer setzt '+' vor positive Betraege, z. B. Gewinn seit Kauf); der
--   Schluessel fehlt sonst, damit bestehende Werte unveraendert bleiben.
--   p_whole = true -> zusaetzlich digits:0: der Renderer zeigt ganze Einheiten (Schaetzwerte).
--   Der Wert bleibt genau (2 Stellen): card_lines stehen auch im Tool-Ergebnis, das Modell darf dort keinen
--   gerundeten Wert lesen. Wer nie ueber einer Grenze anzeigen darf ("hoechstens …"), rundet vorher selbst ab.
--   Name und Verhalten stabil halten (Karten-Texte und Uebersicht nutzen sie).
--   Rueckgabe: {kind:'money', value, currency[, sign:true][, digits:0]}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
-- Alte Signaturen muessen weg, sonst waeren Aufrufe mehrdeutig.
DROP FUNCTION IF EXISTS core.fn_ui_money(numeric, text);
DROP FUNCTION IF EXISTS core.fn_ui_money(numeric, text, boolean);
CREATE OR REPLACE FUNCTION core.fn_ui_money(p_value numeric, p_currency text DEFAULT 'EUR', p_sign boolean DEFAULT FALSE,
                                            p_whole boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'money', 'value', round(p_value, 2), 'currency', COALESCE(p_currency, 'EUR'))
           || CASE WHEN p_sign THEN '{"sign":true}'::jsonb ELSE '{}'::jsonb END
           || CASE WHEN p_whole THEN '{"digits":0}'::jsonb ELSE '{}'::jsonb END;
$$;
