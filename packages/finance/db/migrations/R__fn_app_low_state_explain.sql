-- ============================================================
-- fn_app_low_state_explain (READ, STABLE) -- Erklaerzeile und „Das kannst du tun“ zur Pille des Urteils „Tiefster Stand“
--   Urteil = finance.fn_account_low_state, Pille = finance.fn_app_low_state_pill; die Pille ist kurz, Betrag und Grund
--   stehen hier (docs/reference/ui.md, Pillen und Erklaerung). Der Renderer setzt das Info-Zeichen an Pille und Zeile.
--   p_account gesetzt: Spiegel am Sparplan, die Saetze nennen das Abbuchungskonto (der Aufrufer gibt nur sichtbare Namen).
--   p_month_row: Konten-Zeile „Reicht bis“, Grund Netto-Abfluss wie in der Pille.
--   p_ask_name: Kontoname fuer die Chat-Nachricht ask an der Zeile todo (am Sparplan genuegt p_account).
--   Alter Auszug: nur die Erklaerzeile, sie nennt die Handlung schon.
--   RUECKGABE: jsonb-Array [{label, value:null, kind:'info'}, {label, value:null, kind:'todo', ask?}]; ohne Pille [].
--   plpgsql (late-bound: core.fn_ui_* sind core-R__).
--   Tests: tests/db/finance/test_fn_app_low_state_explain.sql
-- ============================================================
DROP FUNCTION IF EXISTS finance.fn_app_low_state_explain(jsonb, text, boolean);
CREATE OR REPLACE FUNCTION finance.fn_app_low_state_explain(p_ls jsonb, p_account text DEFAULT NULL, p_month_row boolean DEFAULT FALSE,
                                                            p_ask_name text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql STABLE
AS $$
DECLARE
    v_cur   text := p_ls ->> 'currency';
    v_net   numeric := -(COALESCE((p_ls ->> 'monthly_out')::numeric, 0) + COALESCE((p_ls ->> 'monthly_in')::numeric, 0));
    v_plan  boolean := p_account IS NOT NULL;
    v_acc   jsonb := CASE WHEN p_account IS NOT NULL THEN jsonb_build_object('account', p_account) ELSE '{}'::jsonb END;
    v_info  jsonb;
    v_todo  text;
    v_name  text := COALESCE(p_account, p_ask_name);
BEGIN
    IF (p_ls ->> 'ok') IS DISTINCT FROM 'true' OR COALESCE(p_ls ->> 'state', '') NOT IN ('warn', 'alert') THEN
        RETURN '[]'::jsonb;
    END IF;
    IF p_ls ->> 'verdict' = 'stale' THEN
        v_info := core.fn_ui_tpl(CASE WHEN v_plan THEN 'finance.app.goals.i_plan_stale' ELSE 'finance.app.accounts.i_stale' END, v_acc);
    ELSIF p_ls ->> 'verdict' = 'buffer' AND p_ls ->> 'state' = 'warn' THEN
        v_info := core.fn_ui_tpl(CASE WHEN v_plan THEN 'finance.app.goals.i_plan_tight' ELSE 'finance.app.accounts.i_tight' END,
                      v_acc || jsonb_build_object('buffer', core.fn_ui_money((p_ls ->> 'buffer')::numeric, v_cur)));
        v_todo := 'finance.app.accounts.todo_low';
    ELSIF p_ls ->> 'verdict' = 'buffer' THEN
        v_info := core.fn_ui_tpl(CASE WHEN v_plan THEN 'finance.app.goals.i_plan_short' ELSE 'finance.app.accounts.i_short' END, v_acc || jsonb_build_object(
                      'amount', core.fn_ui_money((p_ls ->> 'short_by')::numeric, v_cur),
                      'buffer', core.fn_ui_money((p_ls ->> 'buffer')::numeric, v_cur)));
        v_todo := 'finance.app.accounts.todo_low';
    ELSIF p_month_row AND v_net > 0 THEN
        v_info := core.fn_ui_tpl('finance.app.accounts.i_net_out', jsonb_build_object('amount', core.fn_ui_money(v_net, v_cur)));
        v_todo := 'finance.app.accounts.todo_net_out';
    ELSIF p_ls ->> 'state' = 'warn' AND NOT p_month_row THEN
        v_info := core.fn_ui_tpl(CASE WHEN v_plan THEN 'finance.app.goals.i_plan_until' ELSE 'finance.app.accounts.i_until' END,
                      v_acc || jsonb_build_object('month', core.fn_ui_month((p_ls ->> 'on_date')::date)));
        v_todo := 'finance.app.accounts.todo_gap';
    ELSE
        v_info := core.fn_ui_tpl(CASE WHEN v_plan THEN 'finance.app.goals.i_plan_gap' ELSE 'finance.app.accounts.i_gap' END,
                      v_acc || jsonb_build_object('date', core.fn_ui_date((p_ls ->> 'on_date')::date)));
        v_todo := 'finance.app.accounts.todo_gap';
    END IF;
    IF v_plan AND v_todo IS NOT NULL THEN
        v_todo := 'finance.app.goals.todo_plan';
    END IF;
    RETURN jsonb_build_array(jsonb_build_object('label', v_info, 'value', NULL, 'kind', 'info'))
        || CASE WHEN v_todo IS NOT NULL
                THEN jsonb_build_array(jsonb_build_object('label', core.fn_ui_tpl(v_todo), 'value', NULL, 'kind', 'todo')
                     || CASE WHEN v_name IS NOT NULL
                             THEN jsonb_build_object('ask', core.fn_ui_tpl(CASE v_todo WHEN 'finance.app.accounts.todo_low' THEN 'finance.app.accounts.ask_low'
                                                            WHEN 'finance.app.accounts.todo_net_out' THEN 'finance.app.accounts.ask_net_out'
                                                            WHEN 'finance.app.accounts.todo_gap' THEN 'finance.app.accounts.ask_gap'
                                                            ELSE 'finance.app.goals.ask_plan' END,
                                                       jsonb_build_object('account', v_name)))
                             ELSE '{}'::jsonb END)
                ELSE '[]'::jsonb END;
END;
$$;
