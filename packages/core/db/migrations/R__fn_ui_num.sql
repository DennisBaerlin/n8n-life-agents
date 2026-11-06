-- ============================================================
-- core.fn_ui_num (rein, typisierter Wert fester Texte)
--   Zahl als typisierter Rohwert {kind:'number', value, digits, sign} fuer core.fn_ui_tpl-Parameter (Prozent-
--   punkte, Anteile, Tage); der Workflow formatiert per Intl (feste Nachkommastellen = digits, sign = Vorzeichen
--   auch bei Plus). Jahreszahlen sind KEINE number (Intl gruppiert 2026 -> "2,026"), sondern einfacher Text.
--   RUECKGABE: {kind:'number', value, digits, sign}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_num(p_value numeric, p_digits int DEFAULT 0, p_sign boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'number', 'value', round(p_value, GREATEST(COALESCE(p_digits, 0), 0)),
                              'digits', GREATEST(COALESCE(p_digits, 0), 0), 'sign', COALESCE(p_sign, false));
$$;
