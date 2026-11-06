-- ============================================================
-- core.fn_ui_month (rein, typisierter Wert fester Texte)
--   Monat als typisierter Rohwert {kind:'month', value:'YYYY-MM'} fuer core.fn_ui_tpl-Parameter („reicht bis 04.2027“,
--   „bis 03.2040“); der Workflow formatiert per Intl im Locale des Empfaengers (2-stelliger Monat + Jahr). Der Tag des
--   Eingabedatums faellt weg. NULL -> null (Renderer: '—').
--   p_long = true -> zusaetzlich style 'long': Monatsname, das Jahr nur ausserhalb des Kurz-Fensters (wie bei Datumswerten)
--   („Gehen ab im November“).
--   RUECKGABE: {kind:'month', value[, style:'long']}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
DROP FUNCTION IF EXISTS core.fn_ui_month(date);
CREATE OR REPLACE FUNCTION core.fn_ui_month(p_value date, p_long boolean DEFAULT FALSE)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'month', 'value', to_char(p_value, 'YYYY-MM'))
           || CASE WHEN p_long THEN jsonb_build_object('style', 'long') ELSE '{}'::jsonb END;
$$;
