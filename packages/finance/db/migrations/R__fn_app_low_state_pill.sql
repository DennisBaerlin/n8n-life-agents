-- ============================================================
-- fn_app_low_state_pill (READ, STABLE) -- die EINE Pille zum Urteil „Tiefster Stand" (finance.fn_account_low_state)
--   UX-Gesamtkonzept 2026-10-31 (P3, P12): die Konten-Zeile „Tiefster Stand" (fn_app_screen_accounts) und die
--   Spiegel-Pille am Sparplan (fn_app_screen_goals) zeigen dasselbe Urteil mit demselben Text, deshalb eine Adresse.
--   Nur warn/alert (Handlungsbedarf), Kontowaehrung aus dem Urteil:
--     verdict buffer: warn „knapp ueber dem Puffer ({buffer})" · alert „{short_by} unter dem Puffer"
--     verdict goals:  warn „reicht bis {Monat von on_date}"      · alert „Luecke ab {on_date}"
--   p_month_row = true: Konten-Zeile „Reicht bis" einer Quelle funding, deren WERT schon der Monat ist -> die Pille
--     wiederholt ihn nicht, sondern nennt, warum es nicht reicht: warn/alert „{amount} im Monat mehr ab als rein"
--     (amount = -(monthly_out + monthly_in) > 0); ohne Netto-Abfluss (eine einzelne Abbuchung) den genauen Tag
--     „Luecke ab {on_date}" im Zustand des Urteils. Gleiches Urteil, nur die Form passt zur Zeile.
--   ok / neutral (auch Kurs fehlt) / ohne state / {ok:false} / NULL -> NULL (keine Pille).
--   plpgsql (late-bound: core.fn_ui_* sind core-R__).
--   RUECKGABE: Pille {state, icon, text} | NULL
--   Tests: tests/db/finance/test_fn_app_low_state_pill.sql
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_app_low_state_pill(jsonb);
CREATE OR REPLACE FUNCTION finance.fn_app_low_state_pill(p_ls jsonb, p_month_row boolean DEFAULT FALSE)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_cur text := p_ls ->> 'currency';
    v_net numeric := -(COALESCE((p_ls ->> 'monthly_out')::numeric, 0) + COALESCE((p_ls ->> 'monthly_in')::numeric, 0));
BEGIN
    -- „Kurs fehlt" ist schon state neutral (fn_account_low_state), deshalb keine eigene gap-Regel hier
    IF (p_ls ->> 'ok') IS DISTINCT FROM 'true' OR COALESCE(p_ls ->> 'state', '') NOT IN ('warn', 'alert') THEN
        RETURN NULL;
    END IF;
    IF p_month_row AND p_ls ->> 'verdict' = 'goals' THEN
        RETURN jsonb_build_object('state', p_ls ->> 'state', 'icon', CASE WHEN p_ls ->> 'state' = 'alert' THEN 'alert' ELSE 'calendar' END,
                   'text', CASE WHEN v_net > 0
                                THEN core.fn_ui_tpl('finance.app.accounts.pill_net_out',
                                         jsonb_build_object('amount', core.fn_ui_money(v_net, v_cur)))
                                ELSE core.fn_ui_tpl('finance.app.accounts.pill_gap',
                                         jsonb_build_object('date', core.fn_ui_date((p_ls ->> 'on_date')::date))) END);
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
