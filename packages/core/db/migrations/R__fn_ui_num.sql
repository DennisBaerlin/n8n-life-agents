-- ============================================================
-- fn_ui_num (READ-ONLY, IMMUTABLE — typisierter Wert fester Texte)
--   Eingabe: p_value numeric, p_digits int (Default 0), p_sign boolean (Default false).
--   Zahl als typisierter Rohwert {kind:'number', value, digits, sign} fuer core.fn_ui_tpl-Parameter (Prozent-
--   punkte, Anteile, Tage); der Workflow formatiert per Intl (feste Nachkommastellen = digits, sign = Vorzeichen
--   auch bei Plus). Jahreszahlen sind keine number (Intl gruppiert 2026 -> "2,026"), sondern einfacher Text.
--   Rueckgabe: {kind:'number', value, digits, sign}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_num(p_value numeric, p_digits int DEFAULT 0, p_sign boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'number', 'value', round(p_value, GREATEST(COALESCE(p_digits, 0), 0)),
                              'digits', GREATEST(COALESCE(p_digits, 0), 0), 'sign', COALESCE(p_sign, false));
$$;
