-- ============================================================
-- finance.fn_app_fx_footer(p_currencies text[]) (READ, STABLE) -- Quellen-Hinweis der Wechselkurse fuer einen
--   Mini-App-Bildschirm (view.footer, docs/package-contract.md §3.12). Die Lizenz des freien Kursdienstes
--   (open.er-api.com) verlangt „Rates By Exchange Rate API“ mit Link auf jeder Seite, die seine Kurse benutzt.
--   Eine Adresse fuer Regel, Text-Keys und Link: die fuenf finance.fn_app_screen_* geben nur die Waehrungen ihrer
--   sichtbaren Objekte herein. Ein Kurs gilt als benutzt, wenn mindestens eine Waehrung <> EUR der Liste einen Kurs hat
--   (finance.fn_fx_eur_row); ohne Kurs rechnet die Seite nicht um (Luecke), nur Euro braucht keinen Hinweis.
--   EZB-Zeilen (Ersatzquelle) unterscheidet die fn bewusst nicht: eine Seite mischt meist beide Quellen.
--   Eingabe: p_currencies (NULL/leer -> NULL). Rueckgabe: {text: tpl finance.app.fx_source, link: {text: tpl
--   finance.app.fx_source_link, url}} oder NULL. Seiteneffekte: keine.
--   Tests: tests/db/finance/test_fn_app_fx_footer.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_fx_footer(p_currencies text[])
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
    SELECT CASE WHEN EXISTS (
               SELECT 1 FROM unnest(p_currencies) c(code)
               WHERE c.code IS NOT NULL AND c.code <> 'EUR'
                 AND (SELECT r.rate FROM finance.fn_fx_eur_row(c.code::char(3)) r) IS NOT NULL)
           THEN jsonb_build_object(
               'text', core.fn_ui_tpl('finance.app.fx_source'),
               'link', jsonb_build_object('text', core.fn_ui_tpl('finance.app.fx_source_link'),
                                          'url', 'https://www.exchangerate-api.com'))
           END;
$$;
