-- ============================================================
-- core.fn_ui_month (rein, typisierter Wert fester Texte)
--   Monat als typisierter Rohwert {kind:'month', value:'YYYY-MM'} fuer core.fn_ui_tpl-Parameter („reicht bis 04.2027“,
--   „bis 03.2040“); der Workflow formatiert per Intl im Locale des Empfaengers (2-stelliger Monat + Jahr). Der Tag des
--   Eingabedatums faellt weg. NULL -> null (Renderer: '—').
--   RUECKGABE: {kind:'month', value}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_month(p_value date)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'month', 'value', to_char(p_value, 'YYYY-MM'));
$$;
