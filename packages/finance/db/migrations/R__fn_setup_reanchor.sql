-- ============================================================
-- fn_setup_reanchor (ATOMIC WRITE, hinter dem Gate) -- Startpunkt eines unberuehrten Kontos auf den Anfang der Datei legen
--   Eingabe: chat_id, table:{rows}. Plan und Pruefung: fn_setup_reanchor_plan (Karte und Write lesen dieselben Werte).
--   RUECKGABE: {ok:true, account_id, balance, opening_balance_date, card_lines} | {ok:false, reason}.
--   Trigger trg_finance_balance_update fuehrt den Saldo nach.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_reanchor(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_norm JSONB := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    v_acct INT;
    v_plan JSONB;
    v_open NUMERIC;
    v_date DATE;
BEGIN
    SELECT cash_account_id INTO v_acct FROM finance.setup_session
    WHERE chat_id = p->>'chat_id' AND created_at > now() - interval '7 days' ORDER BY updated_at DESC LIMIT 1;
    IF v_acct IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'There is no open setup with an account.');
    END IF;
    PERFORM 1 FROM finance.account_balances WHERE account_id = v_acct FOR UPDATE;
    v_plan := finance.fn_setup_reanchor_plan(v_acct, v_norm);
    IF (v_plan->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_plan;
    END IF;
    v_open := (v_plan->>'opening_balance')::numeric;
    v_date := (v_plan->>'opening_balance_date')::date;

    IF v_plan->>'opening_tx_id' IS NOT NULL THEN
        DELETE FROM finance.transactions WHERE id = (v_plan->>'opening_tx_id')::int;
    END IF;
    IF v_open <> 0 THEN
        INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
        VALUES (v_acct, v_open, v_date, 'other', 'Eröffnungssaldo');
    END IF;
    UPDATE finance.accounts SET opening_balance_date = v_date WHERE id = v_acct;

    RETURN jsonb_build_object('ok', true, 'account_id', v_acct, 'opening_balance_date', v_date, 'phase', 'statement',
        'say', 'The account start now matches the file. Call tool_import_setup (action continue) now.',
        'balance', finance.fn_get_balance(v_acct),
        'card_lines', jsonb_build_array(
            core.fn_ui_money((v_plan->>'previous_balance')::numeric, v_plan->>'currency') || jsonb_build_object('label', 'finance.label.setup_previous_balance'),
            core.fn_ui_money(v_open, v_plan->>'currency') || jsonb_build_object('label', 'finance.label.setup_new_balance'),
            core.fn_ui_date(v_date) || jsonb_build_object('label', 'finance.label.setup_new_balance_date')));
END;
$$;
