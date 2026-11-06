-- ============================================================
-- fn_app_order_line (READ, STABLE) -- Anzeige-Wert einer Rate fuer die Mini-App: „Betrag · Rhythmus[ · ab Datum]"
--   als typisierter Text-Verweis (View-Modell v1, docs/package-contract.md §3.12; die Seite rechnet nichts).
--   Betrag = abs(amount) je Ausfuehrung in Waehrung des Quellkontos. Rhythmus (fn_schedule_label ist Modell-Text und
--   wird nie angezeigt): monatlich am Tag / an festen Tagen / zum Monatsende (-1) / am vorletzten Tag (-2) / ohne festen
--   Tag nur „monatlich" (kein gerechneter Tag: Laien-Test, Abnahme 2026-10-31); jeder andere Rhythmus nennt die
--   Haeufigkeit (vierteljaehrlich, alle n Monate, jaehrlich, alle n Jahre, woechentlich, alle n Wochen, alle n Tage)
--   + den naechsten Termin (fn_schedule_occurrences).
--   „ab <valid_from>", solange das Glied erst kuenftig startet.
--   Konsument: fn_app_screen_goals (Rate eines Ziels, Sparplan-Rhythmus, geplante Aenderung).
--   RUECKGABE: tpl finance.app.goals.amount_rhythm[_from] | NULL (unbekannte id)
--   Tests: tests/db/finance/test_fn_app_order_line.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_order_line(p_rp_id int)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    r        finance.recurring_payments%ROWTYPE;
    v_cur    CHAR(3);
    v_rhythm JSONB;
    v_from   DATE;
    v_next   DATE;
    v_n      INT;
BEGIN
    SELECT * INTO r FROM finance.recurring_payments WHERE id = p_rp_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    SELECT a.currency INTO v_cur FROM finance.accounts a WHERE a.id = r.account_id;

    v_n := GREATEST(COALESCE(r.schedule_interval, 1), 1);
    IF r.schedule_unit = 'month' AND v_n = 1 AND r.schedule_days_of_month IS NOT NULL THEN
        v_rhythm := core.fn_ui_tpl('finance.app.goals.rhythm_month_days',
                        jsonb_build_object('days', array_to_string(r.schedule_days_of_month, ', ')));
    ELSIF r.schedule_unit = 'month' AND v_n = 1 AND r.schedule_day_of_month = -1 THEN
        v_rhythm := core.fn_ui_tpl('finance.app.goals.rhythm_month_end');
    ELSIF r.schedule_unit = 'month' AND v_n = 1 AND r.schedule_day_of_month = -2 THEN
        v_rhythm := core.fn_ui_tpl('finance.app.goals.rhythm_month_second_last');
    ELSIF r.schedule_unit = 'month' AND v_n = 1 AND r.schedule_day_of_month IS NOT NULL THEN
        v_rhythm := core.fn_ui_tpl('finance.app.goals.rhythm_month_day',
                        jsonb_build_object('day', core.fn_ui_num(r.schedule_day_of_month)));
    ELSIF r.schedule_unit = 'month' AND v_n = 1 THEN
        v_rhythm := core.fn_ui_tpl('finance.app.goals.rhythm_month');
    ELSE
        v_from := GREATEST(current_date, r.valid_from);
        SELECT min(o.d) INTO v_next
        FROM finance.fn_schedule_occurrences(r.first_payment_date, r.schedule_interval, r.schedule_unit,
                 r.schedule_day_of_month, r.schedule_days_of_month, v_from, v_from + 800) AS o(d)
        WHERE r.valid_to IS NULL OR o.d < r.valid_to;
        v_rhythm := CASE
            WHEN r.schedule_unit = 'month' AND v_n = 3 THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_quarterly', jsonb_build_object('date', core.fn_ui_date(v_next)))
            WHEN r.schedule_unit = 'month' THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_months', jsonb_build_object('n', core.fn_ui_num(v_n), 'date', core.fn_ui_date(v_next)))
            WHEN r.schedule_unit = 'year' AND v_n = 1 THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_yearly', jsonb_build_object('date', core.fn_ui_date(v_next)))
            WHEN r.schedule_unit = 'year' THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_years', jsonb_build_object('n', core.fn_ui_num(v_n), 'date', core.fn_ui_date(v_next)))
            WHEN r.schedule_unit = 'week' AND v_n = 1 THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_weekly', jsonb_build_object('date', core.fn_ui_date(v_next)))
            WHEN r.schedule_unit = 'week' THEN
                core.fn_ui_tpl('finance.app.goals.rhythm_weeks', jsonb_build_object('n', core.fn_ui_num(v_n), 'date', core.fn_ui_date(v_next)))
            ELSE
                core.fn_ui_tpl('finance.app.goals.rhythm_days', jsonb_build_object('n', core.fn_ui_num(v_n), 'date', core.fn_ui_date(v_next)))
            END;
    END IF;

    IF r.valid_from > current_date THEN
        RETURN core.fn_ui_tpl('finance.app.goals.amount_rhythm_from', jsonb_build_object(
                   'amount', core.fn_ui_money(abs(r.amount), v_cur), 'rhythm', v_rhythm,
                   'date', core.fn_ui_date(r.valid_from)));
    END IF;
    RETURN core.fn_ui_tpl('finance.app.goals.amount_rhythm', jsonb_build_object(
               'amount', core.fn_ui_money(abs(r.amount), v_cur), 'rhythm', v_rhythm));
END;
$$;
