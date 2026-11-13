-- ============================================================
-- fn_ui_date (READ-ONLY, IMMUTABLE — typisierter Wert fester Texte)
--   Eingabe: p_value date.
--   Datum als typisierter Rohwert {kind:'date', value:'YYYY-MM-DD'} fuer core.fn_ui_tpl-Parameter; der Workflow
--   formatiert per Intl im Locale des Empfaengers. NULL -> null (Renderer: '—').
--   Rueckgabe: {kind:'date', value}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_date(p_value date)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'date', 'value', to_char(p_value, 'YYYY-MM-DD'));
$$;
