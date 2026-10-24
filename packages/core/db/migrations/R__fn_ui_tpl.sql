-- ============================================================
-- core.fn_ui_tpl (rein, Struktur-Baustein fester Texte)
--   Baut einen Text-Verweis in der HITL-Form {kind:'tpl', value:<text-key>, params:{…}} — Pakete liefern damit
--   Struktur statt fertigem (deutschem) Text (Textkatalog Phase C: fn_advisor_review-Alerts/Digest, validate_fn-
--   display); der Workflow rendert sie in der Sprache des Empfaengers (Get-UiRenderLibJs), Zahlen/Daten per Intl.
--   Parameter sind einfache Werte oder typisierte Werte (core.fn_ui_money / fn_ui_num / fn_ui_date / ein weiterer tpl).
--   Der Key MUSS als vollstaendiges Literal im Aufrufer stehen (locale_lint prueft ihn gegen den Katalog).
--   IMMUTABLE, kein Read -> kein DEFINER/Grant (Default-PUBLIC-EXECUTE wie fn_staleness_alert).
--   RUECKGABE: {kind:'tpl', value, params}
--   Tests: tests/db/core/test_fn_ui_values.sql
-- ============================================================
CREATE OR REPLACE FUNCTION core.fn_ui_tpl(p_key text, p_params jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
    SELECT jsonb_build_object('kind', 'tpl', 'value', p_key, 'params', COALESCE(p_params, '{}'::jsonb));
$$;
