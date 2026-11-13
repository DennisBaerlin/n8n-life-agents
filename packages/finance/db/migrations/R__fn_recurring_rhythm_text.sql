-- ============================================================
-- fn_recurring_rhythm_text (STABLE) -- Rhythmus eines Dauerauftrags als Nutzertext in einer Sprache
--   Fuer Texte, die eine DB-fn fertig baut (Knopf-Nachrichten der Dauerauftrags-Vorschlaege); Workflows rendern den
--   Rhythmus selbst. Monatlich ueber die Bank-Zettel-Keys (gleicher Wortlaut wie dort), sonst eigene Keys.
--   Eingabe: p_unit, p_interval, p_dom (Monatstag, -1 = Monatsletzter, -2 = vorletzter), p_lang. Rueckgabe: text.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_recurring_rhythm_text(p_unit text, p_interval int, p_dom int, p_lang text)
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT CASE
        WHEN p_unit = 'month' AND COALESCE(p_interval, 1) = 1 AND p_dom > 0
            THEN core.fn_ui_text('finance.bank_todo.rhythm_month', p_lang, jsonb_build_object('day', p_dom::text))
        WHEN p_unit = 'month' AND COALESCE(p_interval, 1) = 1 AND p_dom = -1
            THEN core.fn_ui_text('finance.bank_todo.rhythm_month_last', p_lang)
        WHEN p_unit = 'month' AND COALESCE(p_interval, 1) = 1 AND p_dom = -2
            THEN core.fn_ui_text('finance.bank_todo.rhythm_month_second_last', p_lang)
        WHEN p_unit = 'month' AND COALESCE(p_interval, 1) = 1 THEN core.fn_ui_text('finance.bank_todo.rhythm_monthly', p_lang)
        WHEN p_unit = 'month' AND p_interval = 3 THEN core.fn_ui_text('finance.recurring_suggest.rhythm_quarterly', p_lang)
        WHEN p_unit = 'month' AND p_interval = 6 THEN core.fn_ui_text('finance.recurring_suggest.rhythm_half_yearly', p_lang)
        WHEN p_unit = 'month' THEN core.fn_ui_text('finance.recurring_suggest.rhythm_months', p_lang, jsonb_build_object('n', p_interval::text))
        WHEN p_unit = 'year' AND COALESCE(p_interval, 1) = 1 THEN core.fn_ui_text('finance.recurring_suggest.rhythm_yearly', p_lang)
        WHEN p_unit = 'week' AND COALESCE(p_interval, 1) = 1 THEN core.fn_ui_text('finance.recurring_suggest.rhythm_weekly', p_lang)
        WHEN p_unit = 'week' THEN core.fn_ui_text('finance.recurring_suggest.rhythm_weeks', p_lang, jsonb_build_object('n', p_interval::text))
        ELSE core.fn_ui_text('finance.bank_todo.rhythm_other', p_lang, jsonb_build_object('n', COALESCE(p_interval, 1)::text,
                 'unit', core.fn_ui_text('finance.enum.schedule_unit' || '.' || COALESCE(p_unit, 'month'), p_lang))) END;
$$;
