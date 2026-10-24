-- ============================================================
-- core.fn_ui_money (rein, typisierter Wert fester Texte)
--   Betrag als typisierter Rohwert {kind:'money', value, currency} fuer core.fn_ui_tpl-Parameter; der Workflow
--   formatiert per Intl im Locale des Empfaengers (nie to_char: das Format hinge an lc_numeric der Session).
--   value auf 2 Stellen gerundet (Anzeige-Wert; gerechnet ist vorher), NULL -> null (Renderer: '—').
--   RUECKGABE: {kind:'money', value, currency}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_money(p_value numeric, p_currency text DEFAULT 'EUR')
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'money', 'value', round(p_value, 2), 'currency', COALESCE(p_currency, 'EUR'));
$$;
