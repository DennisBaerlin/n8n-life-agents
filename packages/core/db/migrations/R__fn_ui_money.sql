-- ============================================================
-- core.fn_ui_money (rein, typisierter Wert fester Texte)
--   Betrag als typisierter Rohwert {kind:'money', value, currency} fuer core.fn_ui_tpl-Parameter; der Workflow
--   formatiert per Intl im Locale des Empfaengers (nie to_char: das Format hinge an lc_numeric der Session).
--   value auf 2 Stellen gerundet (Anzeige-Wert; gerechnet ist vorher), NULL -> null (Renderer: '—').
--   p_sign = true -> zusaetzlich sign:true (Renderer setzt '+' vor positive Betraege, z. B. Gewinn seit Kauf); der
--   Schluessel fehlt sonst, damit bestehende Werte unveraendert bleiben.
--   RUECKGABE: {kind:'money', value, currency[, sign:true]}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
-- Signatur erweitert (Uebersicht R3): die alte 2-Argument-Fassung muss weg, sonst waeren alle Aufrufe mehrdeutig.
DROP FUNCTION IF EXISTS core.fn_ui_money(numeric, text);
CREATE OR REPLACE FUNCTION core.fn_ui_money(p_value numeric, p_currency text DEFAULT 'EUR', p_sign boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'money', 'value', round(p_value, 2), 'currency', COALESCE(p_currency, 'EUR'))
           || CASE WHEN p_sign THEN '{"sign":true}'::jsonb ELSE '{}'::jsonb END;
$$;
