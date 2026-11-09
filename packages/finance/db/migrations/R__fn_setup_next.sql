-- ============================================================
-- fn_setup_next (READ, STABLE) -- naechster Schritt der gefuehrten Ersteinrichtung
--   Leitet den Schritt allein aus Fakten ab (Konto, Depot, Positionen, Antworten), speichert nichts: ein geloeschtes Konto fuehrt
--   zurueck auf den Konto-Schritt. Eingabe: chat_id, table:{rows}, historic_price (opt, Schlusskurs fuer den offenen Punkt).
--   phase: confirm_account | cash_account | reanchor | depot | crypto_depot | positions | open_items | statement | done.
--   RUECKGABE (einheitlich): {ok, phase, say (Anweisung an den Agenten, Englisch), ask?:{key, type, ...}, card?:{tool, params}, done?,
--   account_id, account_name, file_id, profile, interest_source, notes[], held[]} | {ok:false, code:'no_open_setup', reason}.
--   ask.suggested_amount = Stueck x historic_price (estimated:true), die fn rechnet.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_setup_next(p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_s     finance.setup_session%ROWTYPE;
    v_prof  JSONB;
    v_norm  JSONB;
    v_acct  finance.accounts%ROWTYPE;
    v_dec   JSONB;
    v_load  JSONB;
    v_cut   DATE;
    v_pos   JSONB;
    v_head  JSONB;
    v_base  JSONB;
    v_bal   NUMERIC;
    v_sender TEXT;
    v_hist  NUMERIC := NULLIF(p->>'historic_price', '')::numeric;
    v_plan  JSONB;
    v_stock BOOLEAN;
    v_coin  BOOLEAN;
    v_ccy   TEXT;
BEGIN
    SELECT * INTO v_s FROM finance.setup_session
    WHERE chat_id = p->>'chat_id' AND created_at > now() - interval '7 days' ORDER BY updated_at DESC LIMIT 1;
    IF v_s.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'code', 'no_open_setup',
            'reason', 'There is no open first-time setup. Ask the user to send the export file.');
    END IF;
    v_dec := v_s.decisions;
    SELECT pr INTO v_prof FROM jsonb_array_elements(finance.fn_bank_export_profiles()) pr WHERE pr->>'key' = v_s.profile;
    v_norm := finance.fn_bank_export_normalize(COALESCE(p->'table', '{}'::jsonb));
    IF (v_norm->>'ok')::boolean IS DISTINCT FROM true THEN
        RETURN v_norm;
    END IF;

    IF v_s.cash_account_id IS NOT NULL THEN
        SELECT * INTO v_acct FROM finance.accounts WHERE id = v_s.cash_account_id AND status = 'active';
    END IF;
    IF v_acct.id IS NULL THEN
        SELECT a.* INTO v_acct FROM finance.accounts a
        WHERE a.status = 'active' AND finance.fn_bank_export_account_profile(a.id) = v_s.profile
          AND finance.fn_bookable_account_reason(a.id) IS NULL
          AND a.id::text IS DISTINCT FROM v_dec->>'rejected_account'
          AND (SELECT count(*) FROM finance.accounts b
               WHERE b.status = 'active' AND finance.fn_bank_export_account_profile(b.id) = v_s.profile
                 AND finance.fn_bookable_account_reason(b.id) IS NULL AND b.id::text IS DISTINCT FROM v_dec->>'rejected_account') = 1;
    END IF;

    v_ccy := COALESCE(v_acct.currency, v_norm->'currencies'->>0, 'EUR');
    v_base := jsonb_build_object('ok', true, 'file_id', v_s.file_id, 'profile', v_s.profile, 'currency', v_ccy,
        'bank', v_prof->>'bank', 'interest_source', v_prof->>'interest_source',
        'account_id', v_acct.id, 'account_name', v_acct.name);

    IF v_acct.id IS NULL THEN
        v_load := finance.fn_bank_export_load(jsonb_build_object('table', p->'table'));
        v_plan := v_load->'opening_anchor';
        IF (v_plan->>'balance_verified')::boolean THEN
            RETURN v_base || jsonb_build_object('phase', 'cash_account',
                'say', 'Create the account with tool_create_account using card.params verbatim. Do not ask for the balance and do not enter interest: the real interest comes from this file. Afterwards call tool_import_setup.',
                'card', jsonb_build_object('tool', 'tool_create_account', 'params', jsonb_build_object(
                    'name', v_prof->>'bank', 'bank', v_prof->>'bank', 'account_type', v_prof->>'default_account_type', 'currency', v_ccy,
                    'opening_balance', v_plan->'opening_balance', 'opening_balance_date', v_plan->'opening_balance_date')));
        END IF;
        v_bal := (v_dec->>'current_balance')::numeric;
        IF v_bal IS NULL THEN
            RETURN v_base || jsonb_build_object('phase', 'cash_account',
                'say', 'Ask the user for the current balance of this account exactly as the bank app shows it right now (one short question), then call tool_import_setup with question_key current_balance and the value as answer.',
                'ask', jsonb_build_object('key', 'current_balance', 'type', 'current_balance'));
        END IF;
        RETURN v_base || jsonb_build_object('phase', 'cash_account',
            'say', CASE WHEN v_prof->>'interest_source' = 'web'
                        THEN 'Look up the public interest conditions of this bank account once with web_search (query = bank and product only, never personal data); ask the user only for what the source does not give (never assume the crediting day). Then create the account with tool_create_account using card.params plus the interest terms: the approval card is the offer. Afterwards call tool_import_setup.'
                        ELSE 'Create the account with tool_create_account using card.params verbatim (no interest). Afterwards call tool_import_setup.' END,
            'card', jsonb_build_object('tool', 'tool_create_account', 'params', jsonb_build_object(
                'name', v_prof->>'bank', 'bank', v_prof->>'bank', 'account_type', v_prof->>'default_account_type', 'currency', v_ccy,
                'opening_balance', v_bal)));
    END IF;

    SELECT r.person_id INTO v_sender FROM core.fn_resolve_person('me', p->>'chat_id') r WHERE r.hit_count = 1;
    IF v_acct.owner_person_id IS NOT NULL AND v_sender IS NOT NULL AND v_acct.owner_person_id <> v_sender
       AND (v_dec->>'account_confirmed')::boolean IS DISTINCT FROM true THEN
        RETURN v_base || jsonb_build_object('phase', 'confirm_account',
            'say', 'The only account of this bank belongs to another household member. Ask the user whether the file belongs to that account, then call tool_import_setup with question_key confirm_account and answer yes or no.',
            'ask', jsonb_build_object('key', 'confirm_account', 'type', 'confirm_account', 'account_name', v_acct.name));
    END IF;

    IF (v_prof->>'printed_balance')::boolean THEN
        v_plan := finance.fn_setup_reanchor_plan(v_acct.id, v_norm);
        IF (v_plan->>'ok')::boolean THEN
            RETURN v_base || jsonb_build_object('phase', 'reanchor',
                'say', 'The account was created with a later balance, so this file would add nothing. Call tool_import_setup with action reanchor: the approval card moves the account start to the beginning of the file.',
                'card', jsonb_build_object('tool', 'tool_import_setup', 'params', jsonb_build_object('action', 'reanchor')));
        END IF;
    END IF;

    IF (v_prof->>'is_broker')::boolean THEN
        v_cut := COALESCE(GREATEST(v_acct.last_reconciled_at, v_acct.opening_balance_date), core.fn_today());
        v_pos := finance.fn_setup_positions(v_norm->'rows', v_dec, v_acct.id, v_cut);
        v_base := v_base || jsonb_build_object('notes', v_pos->'notes', 'held', v_pos->'held');
        SELECT COALESCE(bool_or(NOT (x->>'is_crypto')::boolean), false), COALESCE(bool_or((x->>'is_crypto')::boolean), false)
        INTO v_stock, v_coin FROM jsonb_array_elements(v_pos->'positions') x;
        v_stock := v_stock OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_pos->'open_items') o WHERE o->>'isin' IS NOT NULL);
        v_coin  := v_coin OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_pos->'open_items') o WHERE o->>'isin' IS NULL AND o->>'symbol' IS NOT NULL);
        IF v_stock AND NOT EXISTS (SELECT 1 FROM finance.accounts d WHERE d.settlement_account_id = v_acct.id AND d.status = 'active' AND d.account_type::text = 'stocks_depot') THEN
            RETURN v_base || jsonb_build_object('phase', 'depot',
                'say', 'Create the depot with tool_create_account using card.params verbatim. Afterwards call tool_import_setup.',
                'card', jsonb_build_object('tool', 'tool_create_account', 'params', jsonb_build_object(
                    'name', (v_prof->>'bank') || ' Depot', 'bank', v_prof->>'bank', 'account_type', 'stocks_depot', 'currency', v_acct.currency, 'settlement_account_name', v_acct.name)));
        END IF;
        IF v_coin AND NOT EXISTS (SELECT 1 FROM finance.accounts d WHERE d.settlement_account_id = v_acct.id AND d.status = 'active' AND d.account_type::text = 'crypto_depot') THEN
            RETURN v_base || jsonb_build_object('phase', 'crypto_depot',
                'say', 'Create the crypto depot with tool_create_account using card.params verbatim. Afterwards call tool_import_setup.',
                'card', jsonb_build_object('tool', 'tool_create_account', 'params', jsonb_build_object(
                    'name', (v_prof->>'bank') || ' Krypto', 'bank', v_prof->>'bank', 'account_type', 'crypto_depot', 'currency', v_acct.currency, 'settlement_account_name', v_acct.name)));
        END IF;
        IF jsonb_array_length(v_pos->'positions') > 0 THEN
            RETURN v_base || jsonb_build_object('phase', 'positions', 'positions', v_pos->'positions',
                'say', 'The positions are staged from the file. Call tool_commit_import with the batch_id: one card shows them. Afterwards call tool_import_setup.');
        END IF;
        IF jsonb_array_length(v_pos->'open_items') > 0 THEN
            v_head := v_pos->'open_items'->0;
            RETURN v_base || jsonb_build_object('phase', 'open_items', 'open_count', jsonb_array_length(v_pos->'open_items'),
                'say', CASE WHEN v_head->>'type' IN ('mixed_currency', 'position_incomplete', 'merger_unclear')
                            THEN 'This position cannot be derived from the file. Tell the user in plain words and that it can be entered by hand later, then call tool_import_setup with this question_key and answer skip. Other positions are already done.'
                            WHEN v_hist > 0 AND (v_head->>'shares')::numeric > 0
                            THEN 'Offer ask.suggested_amount as an ESTIMATED cost from the historic price of that day (say it is an estimate). The user accepts (answer accept), names another amount (amount) or leaves the position out (answer skip); then call tool_import_setup with this question_key. Never use 0.'
                            ELSE 'The file gives no cost for this position. Ask the user for the total cost or to leave it out; then call tool_import_setup with this question_key and amount, or answer skip. Never use 0.' END,
                'ask', v_head || CASE WHEN v_hist > 0 AND (v_head->>'shares')::numeric > 0
                                      THEN jsonb_build_object('suggested_amount', round((v_head->>'shares')::numeric * v_hist, 2), 'estimated', true, 'ref_price', v_hist)
                                      ELSE '{}'::jsonb END);
        END IF;
    END IF;

    IF (v_prof->>'printed_balance')::boolean THEN
        RETURN v_base || jsonb_build_object('phase', 'statement',
            'say', 'Call tool_import_bank_export with file_id: the file is now booked as the first monthly check of the new account.',
            'card', jsonb_build_object('tool', 'tool_import_bank_export', 'params', jsonb_build_object('file_id', v_s.file_id)));
    END IF;
    RETURN v_base || jsonb_build_object('phase', 'done', 'done', true,
        'say', 'The setup is complete. Summarise it in one or two sentences; name what was left out, if anything.');
END;
$$;
