-- ============================================================
-- fn_app_low_state_pill (READ, STABLE) -- die EINE Pille zum Urteil „Tiefster Stand" (finance.fn_account_low_state)
--   UX-Gesamtkonzept 2026-10-31 (P3, P12): die Konten-Zeile „Tiefster Stand" (fn_app_screen_accounts) und die
--   Spiegel-Pille am Sparplan (fn_app_screen_goals) zeigen dasselbe Urteil mit demselben Text, deshalb eine Adresse.
--   Nur warn/alert (Handlungsbedarf), Kontowaehrung aus dem Urteil:
--     verdict buffer: warn „knapp ueber dem Puffer ({buffer})" · alert „{short_by} unter dem Puffer"
--     verdict goals:  warn „reicht bis {Monat von on_date}"      · alert „Luecke ab {on_date}"
--   ok / neutral (auch Kurs fehlt) / ohne state / {ok:false} / NULL -> NULL (keine Pille).
--   plpgsql (late-bound: core.fn_ui_* sind core-R__).
--   RUECKGABE: Pille {state, icon, text} | NULL
--   Tests: tests/db/finance/test_fn_app_low_state_pill.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_low_state_pill(p_ls jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_cur text := p_ls ->> 'currency';
BEGIN
    -- „Kurs fehlt" ist schon state neutral (fn_account_low_state), deshalb keine eigene gap-Regel hier
    IF (p_ls ->> 'ok') IS DISTINCT FROM 'true' OR COALESCE(p_ls ->> 'state', '') NOT IN ('warn', 'alert') THEN
        RETURN NULL;
    END IF;
    RETURN CASE
        WHEN p_ls ->> 'verdict' = 'buffer' AND p_ls ->> 'state' = 'warn'
        THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_tight',
                             jsonb_build_object('buffer', core.fn_ui_money((p_ls ->> 'buffer')::numeric, v_cur))))
        WHEN p_ls ->> 'verdict' = 'buffer'
        THEN jsonb_build_object('state', 'alert', 'icon', 'alert',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_short',
                             jsonb_build_object('amount', core.fn_ui_money((p_ls ->> 'short_by')::numeric, v_cur))))
        WHEN p_ls ->> 'state' = 'warn'
        THEN jsonb_build_object('state', 'warn', 'icon', 'calendar',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_until',
                             jsonb_build_object('month', core.fn_ui_month((p_ls ->> 'on_date')::date))))
        ELSE jsonb_build_object('state', 'alert', 'icon', 'alert',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_gap',
                             jsonb_build_object('date', core.fn_ui_date((p_ls ->> 'on_date')::date)))) END;
END;
$$;
