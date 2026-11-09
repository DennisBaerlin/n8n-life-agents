-- ============================================================
-- fn_app_low_state_pill (READ, STABLE) -- die EINE Pille zum Urteil „Tiefster Stand" (finance.fn_account_low_state)
--   UX-Gesamtkonzept 2026-10-31 (P3, P12): die Konten-Zeile „Tiefster Stand" (fn_app_screen_accounts) und die
--   Spiegel-Pille am Sparplan (fn_app_screen_goals) zeigen dasselbe Urteil mit demselben Text, deshalb eine Adresse.
--   Nur warn/alert (Handlungsbedarf), Kontowaehrung aus dem Urteil:
--     verdict stale:  warn „neuer Kontoauszug"
--     verdict buffer: warn „knapp ueber Puffer" · alert „unter Puffer" (Betraege: fn_app_low_state_explain)
--     verdict goals:  warn „wird knapp" · alert „Luecke" (Monat und Tag: fn_app_low_state_explain; Pille traegt keine Daten)
--   p_month_row = true: Konten-Zeile „Reicht bis" einer Quelle funding: die Pille nennt, warum es nicht reicht:
--     warn/alert „Monatsminus" (-(monthly_out + monthly_in) > 0); ohne Netto-Abfluss (eine einzelne Abbuchung)
--     „Luecke" im Zustand des Urteils. Gleiches Urteil, nur die Form passt zur Zeile.
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
    IF p_ls ->> 'verdict' = 'stale' THEN
        RETURN jsonb_build_object('state', 'warn', 'icon', 'clock', 'text', core.fn_ui_tpl('finance.app.accounts.pill_stale'));
    END IF;
    IF p_month_row AND p_ls ->> 'verdict' = 'goals' THEN
        RETURN jsonb_build_object('state', p_ls ->> 'state', 'icon', CASE WHEN p_ls ->> 'state' = 'alert' THEN 'alert' ELSE 'calendar' END,
                   'text', CASE WHEN v_net > 0
                                THEN core.fn_ui_tpl('finance.app.accounts.pill_net_out')
                                ELSE core.fn_ui_tpl('finance.app.accounts.pill_gap') END);
    END IF;
    RETURN CASE
        WHEN p_ls ->> 'verdict' = 'buffer' AND p_ls ->> 'state' = 'warn'
        THEN jsonb_build_object('state', 'warn', 'icon', 'clock',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_tight'))
        WHEN p_ls ->> 'verdict' = 'buffer'
        THEN jsonb_build_object('state', 'alert', 'icon', 'alert',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_short'))
        WHEN p_ls ->> 'state' = 'warn'
        THEN jsonb_build_object('state', 'warn', 'icon', 'calendar',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_until'))
        ELSE jsonb_build_object('state', 'alert', 'icon', 'alert',
                 'text', core.fn_ui_tpl('finance.app.accounts.pill_gap')) END;
END;
$$;
