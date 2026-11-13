-- ============================================================
-- fn_ui_tpl (READ-ONLY, IMMUTABLE — Struktur-Baustein fester Texte)
--   Eingabe: p_key text, p_params jsonb (Default {}).
--   Baut einen Text-Verweis in der HITL-Form {kind:'tpl', value:<text-key>, params:{…}} — Pakete liefern damit
--   Struktur statt fertigem (deutschem) Text (fn_advisor_review-Alerts/Digest, validate_fn-
--   display); der Workflow rendert sie in der Sprache des Empfaengers (Get-UiRenderLibJs), Zahlen/Daten per Intl.
--   Parameter sind einfache Werte oder typisierte Werte (core.fn_ui_money / fn_ui_num / fn_ui_date / fn_ui_month / ein weiterer tpl).
--   Der Key muss als vollstaendiges Literal im Aufrufer stehen (locale_lint prueft ihn gegen den Katalog).
--   Kein Read -> kein DEFINER/Grant (Default-PUBLIC-EXECUTE wie fn_staleness_alert).
--   Rueckgabe: {kind:'tpl', value, params}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_tpl(p_key text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'tpl', 'value', p_key, 'params', COALESCE(p_params, '{}'::jsonb));
$$;
