-- ============================================================
-- finance.fn_handle_recurring_suggestion_cb(p) -- Registry-Handler des Callback-Prefix 'rsug' (member_permeable)
--   Knopf rsug:ok:<id>:<version> bzw. rsug:no:<id>:<version> unter einer Vorschlags-Nachricht. Der Tipp ist die
--   Bestaetigung (kein HITL-Gate): angelegt wird allein aus dem gespeicherten Payload (fn_recurring_suggestion_args), die
--   Anlege-fn bleibt das Gesetz (Dubletten, IBAN), dazu fn_recurring_known gegen inzwischen Angelegtes.
--   Nur Privatchat; Sender selbst aufgeloest: Owner alle Vorschlaege, erwachsenes Mitglied (partner) nur die aus dem
--   eigenen Chat, Kind nichts. Zeile FOR UPDATE gesperrt: fehlt -> "abgelaufen", committed -> "schon uebernommen",
--   declined -> "schon abgelehnt", andere Fassung -> "ueberholt"; jeweils edit {keep_text} (Knoepfe weg, Text bleibt),
--   nichts angelegt. ok: Anlage mit chat_id des Tippenden, Zeile committed (+ recurring_payment_id, Payload auf Name
--   gekuerzt), Text aus der angelegten Zeile (Name, Betrag, Rhythmus, Start, Konto); Ablehnung der Anlege-fn oder schon
--   bekannt -> declined + Text mit Grund. no: declined. Uebernimmt ein Mitglied, liefert owner_notice den Hinweis in
--   Owner-Sprache (Gleichstand zur Stufe owner_info der Einzelanlage). Die fn ist schnell, deshalb kommt der Toast aus
--   ihrem Ergebnis (kein answerCallbackQuery vorab).
--   p: {data, chat_id, chat_type}. Rueckgabe {ok, toast, edit?:{text}|{keep_text:true}, owner_notice?} | {ok:false, reason,
--   toast}. Nie RAISE.
--   Tests: tests/db/finance/test_fn_handle_recurring_suggestion_cb.sql
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_handle_recurring_suggestion_cb(p jsonb)
RETURNS jsonb
LANGUAGE plpgsql VOLATILE
SET search_path = pg_catalog, pg_temp
AS $$
DECLARE
    v_data  text := COALESCE(p->>'data', '');
    v_verb  text := split_part(v_data, ':', 2);
    v_id    text := split_part(v_data, ':', 3);
    v_ver   text := split_part(v_data, ':', 4);
    v_chat  text := COALESCE(p->>'chat_id', '');
    v_s     jsonb;
    v_lang  text;
    v_row   finance.import_staging%ROWTYPE;
    v_args  jsonb;
    v_res   jsonb;
    v_rp    record;
    v_info  jsonb;
    v_known jsonb;
    v_rpid  int;
    v_owner text;
    v_keep  jsonb := jsonb_build_object('keep_text', true);
BEGIN
    IF v_chat ~ '^[0-9]{1,18}$' THEN v_s := agent.fn_resolve_sender(v_chat::bigint); END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';
    IF COALESCE(p->>'chat_type', '') <> 'private' OR v_s->>'role' IS NULL OR v_s->>'role' NOT IN ('owner', 'partner') THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed',
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_not_allowed', v_lang));
    END IF;
    IF v_verb NOT IN ('ok', 'no') OR v_id !~ '^[0-9]{1,9}$' OR v_ver !~ '^[0-9]{1,9}$'
       OR v_data <> 'rsug:' || v_verb || ':' || v_id || ':' || v_ver THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'unknown', 'edit', v_keep,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_expired', v_lang));
    END IF;
    SELECT * INTO v_row FROM finance.import_staging
    WHERE id = v_id::int AND origin = 'recurring_suggestion' FOR UPDATE;
    IF v_row.id IS NULL THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'expired', 'edit', v_keep,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_expired', v_lang));
    END IF;
    IF v_s->>'role' <> 'owner' AND v_row.chat_id IS DISTINCT FROM v_chat THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'not_allowed',
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_not_allowed', v_lang));
    END IF;
    IF v_row.status = 'committed' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'already_committed', 'edit', v_keep,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_already_taken', v_lang));
    ELSIF v_row.status = 'declined' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'already_declined', 'edit', v_keep,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_already_declined', v_lang));
    ELSIF v_row.version <> v_ver::int THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'outdated', 'edit', v_keep,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_outdated', v_lang));
    END IF;

    v_info := jsonb_build_object('name', v_row.payload->>'name');
    IF v_verb = 'no' THEN
        UPDATE finance.import_staging SET status = 'declined' WHERE id = v_row.id;
        RETURN jsonb_build_object('ok', true, 'declined', true,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_declined', v_lang),
            'edit', jsonb_build_object('text', finance.fn_recurring_suggestion_text('declined', v_info, v_lang)));
    END IF;

    v_known := finance.fn_recurring_known(jsonb_build_object(
        'account_id', v_row.payload->'account_id',
        'sign', CASE WHEN v_row.payload->>'direction' = 'income' OR v_row.payload->>'to_account_id' = v_row.payload->>'account_id' THEN 1 ELSE -1 END,
        'amount', v_row.payload->'amount', 'iban', v_row.payload->>'counterparty_iban',
        'other_account_id', CASE WHEN v_row.entity_type = 'recurring_transfer' THEN
                                 COALESCE(NULLIF(v_row.payload->>'to_account_id', v_row.payload->>'account_id'), v_row.payload->>'from_account_id') END,
        'unit', v_row.payload->>'schedule_unit', 'interval', v_row.payload->'schedule_interval',
        'dom', v_row.payload->'schedule_day_of_month', 'name', v_row.payload->>'name',
        'mandate', CASE WHEN v_row.payload ? 'mandate_ref' THEN upper(v_row.payload->>'creditor_id') || '|' || upper(v_row.payload->>'mandate_ref') END));
    IF (v_known->>'known')::boolean THEN
        UPDATE finance.import_staging SET status = 'declined', validation_error = 'already_known' WHERE id = v_row.id;
        RETURN jsonb_build_object('ok', false, 'reason', 'already_known',
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_declined', v_lang),
            'edit', jsonb_build_object('text', finance.fn_recurring_suggestion_text('failed',
                        v_info || jsonb_build_object('reason_key', 'finance.recurring_suggest.reason_known'), v_lang)));
    END IF;

    v_args := finance.fn_recurring_suggestion_args(v_row.payload) || jsonb_build_object('chat_id', v_chat);
    BEGIN
        v_res := CASE WHEN v_row.entity_type = 'recurring_transfer' THEN finance.fn_create_recurring_transfer(v_args)
                      ELSE finance.fn_create_recurring_payment(v_args) END;
    EXCEPTION WHEN OTHERS THEN
        v_res := jsonb_build_object('ok', false, 'reason', 'error');
    END;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        UPDATE finance.import_staging SET status = 'declined', validation_error = left(COALESCE(v_res->>'reason', 'rejected'), 300)
        WHERE id = v_row.id;
        RETURN jsonb_build_object('ok', false, 'reason', 'create_rejected',
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_declined', v_lang),
            'edit', jsonb_build_object('text', finance.fn_recurring_suggestion_text('failed', v_info, v_lang)));
    END IF;

    v_rpid := (v_res->>'recurring_payment_id')::int;
    -- Post-State-Vertrag: die Anlege-fn gibt keine Eingaben zurueck -> die angelegte Zeile selbst lesen
    SELECT r.name, abs(r.amount) AS amount, r.schedule_unit::text AS unit, r.schedule_interval AS iv, r.schedule_day_of_month AS dom,
           GREATEST(r.first_payment_date, r.valid_from) AS start, a.name AS account, a.currency, t.name AS to_account
    INTO v_rp
    FROM finance.recurring_payments r
    JOIN finance.accounts a ON a.id = r.account_id
    LEFT JOIN finance.accounts t ON t.id = r.target_account_id
    WHERE r.id = v_rpid;
    v_info := jsonb_build_object('name', v_rp.name, 'entity_type', v_row.entity_type, 'amount', v_rp.amount, 'currency', v_rp.currency,
                                 'unit', v_rp.unit, 'interval', v_rp.iv, 'dom', v_rp.dom, 'start', v_rp.start,
                                 'account', v_rp.account, 'to_account', v_rp.to_account);
    -- uebernommen: auf Name, id und Status kuerzen (Termine und IBAN weg), bis zum Aufraeumen
    UPDATE finance.import_staging SET status = 'committed', recurring_payment_id = v_rpid,
           payload = jsonb_build_object('name', v_rp.name, 'account_id', v_row.payload->'account_id')
    WHERE id = v_row.id;
    IF v_s->>'role' <> 'owner' THEN
        v_owner := agent.fn_person_lang(agent.fn_owner_person_id())->>'lang';
        RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_rpid,
            'toast', core.fn_ui_text('finance.recurring_suggest.toast_accepted', v_lang),
            'edit', jsonb_build_object('text', finance.fn_recurring_suggestion_text('accepted', v_info, v_lang)),
            'owner_notice', finance.fn_recurring_suggestion_text('owner_notice',
                                v_info || jsonb_build_object('member', v_s->>'first_name'), v_owner));
    END IF;
    RETURN jsonb_build_object('ok', true, 'recurring_payment_id', v_rpid,
        'toast', core.fn_ui_text('finance.recurring_suggest.toast_accepted', v_lang),
        'edit', jsonb_build_object('text', finance.fn_recurring_suggestion_text('accepted', v_info, v_lang)));
EXCEPTION WHEN OTHERS THEN
    RETURN jsonb_build_object('ok', false, 'reason', 'error',
        'toast', core.fn_ui_text('finance.recurring_suggest.toast_expired', v_lang));
END;
$$;
