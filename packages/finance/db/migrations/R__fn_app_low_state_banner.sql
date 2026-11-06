-- ============================================================
-- fn_app_low_state_banner (READ, STABLE) -- der EINE Startseiten-Hinweis zum Urteil „Tiefster Stand" eines Kontos
--   Urteil = finance.fn_account_low_state. Konsumenten: probe von fn_app_screen_accounts (gelistete Konten) und probe von
--   fn_app_screen_goals (Abbuchungskonten von Sparplaenen, die der Konten-Tab NICHT zeigt: Kinder-Konten in der
--   Haushalts-Sicht, finance.fn_app_accounts_listed). Dieselbe Lage, derselbe Satz; welche Zustaende ein Bildschirm
--   meldet und wohin der Tipp fuehrt (target), entscheidet der Aufrufer.
--   Banner nur bei Handlungsbedarf: alert (verdict goals „reicht nur bis {on_date}", verdict buffer „unter dem Puffer"
--   mit tiefstem Stand + Tag des Tiefs, mit Umbuchungs-Vorschlag p_sugg {amount, from_account, by_date} die
--   _suggest-Fassung) und warn nur bei verdict buffer („Es wird knapp"; ein gelbes „reicht bis" stuende monatelang da).
--   ok / neutral (auch Kurs fehlt) / ohne state / {ok:false} / NULL -> NULL. p_account = Name, wie der Betrachter ihn
--   sehen darf (Aufrufer).
--   plpgsql (late-bound: core.fn_ui_* sind core-R__).
--   RUECKGABE: {state, icon, text} | NULL
--   Tests: tests/db/finance/test_fn_app_low_state_banner.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_app_low_state_banner(p_ls jsonb, p_account text, p_sugg jsonb)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_cur text := p_ls ->> 'currency';
    v_min jsonb;
    v_day jsonb;
BEGIN
    -- „Kurs fehlt" ist schon state neutral (fn_account_low_state), deshalb keine eigene gap-Regel hier
    IF (p_ls ->> 'ok') IS DISTINCT FROM 'true'
       OR NOT COALESCE(p_ls ->> 'state' = 'alert' OR (p_ls ->> 'state' = 'warn' AND p_ls ->> 'verdict' = 'buffer'), false) THEN
        RETURN NULL;
    END IF;
    v_min := core.fn_ui_money((p_ls ->> 'amount')::numeric, v_cur);
    v_day := core.fn_ui_date((p_ls ->> 'low_date')::date);
    RETURN jsonb_build_object(
        'state', p_ls ->> 'state',
        'icon', CASE WHEN p_ls ->> 'state' = 'warn' THEN 'clock' ELSE 'alert' END,
        'text', CASE
            WHEN p_ls ->> 'verdict' = 'goals' THEN core.fn_ui_tpl('finance.app.accounts.banner_gap',
                jsonb_build_object('account', p_account, 'date', core.fn_ui_date((p_ls ->> 'on_date')::date)))
            WHEN p_ls ->> 'state' = 'warn' THEN core.fn_ui_tpl('finance.app.accounts.banner_tight',
                jsonb_build_object('account', p_account, 'min', v_min, 'date', v_day))
            WHEN jsonb_typeof(p_sugg) = 'object' THEN core.fn_ui_tpl('finance.app.accounts.banner_short_suggest',
                jsonb_build_object('account', p_account, 'min', v_min, 'date', v_day,
                    'amount', core.fn_ui_money((p_sugg ->> 'amount')::numeric, v_cur),
                    'from', p_sugg ->> 'from_account', 'by', core.fn_ui_date((p_sugg ->> 'by_date')::date)))
            ELSE core.fn_ui_tpl('finance.app.accounts.banner_short',
                jsonb_build_object('account', p_account, 'min', v_min, 'date', v_day)) END);
END;
$$;
