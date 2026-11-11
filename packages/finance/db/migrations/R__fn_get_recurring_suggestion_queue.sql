-- ============================================================
-- fn_get_recurring_suggestion_queue (VOLATILE: Probelauf) -- welche Dauerauftrags-Vorschlaege gehen jetzt als Knopf-Nachricht
--   Fuer tool_send_recurring_suggestions. Offene Zeilen des nicht abgelaufenen (fn_recurring_suggestion_expired) Vorschlags-Stapels dieses Chats, deren aktuelle Fassung noch
--   nicht geschickt wurde (sent_version <> version), zuerst sure, dann confirm, je nach Betrag absteigend; hoechstens 10
--   je Aufruf (Rest = more). Kinder und Unbekannte bekommen nichts. Je Zeile: Sicherheit neu aus den Terminen
--   (fn_recurring_suggestion_measure; NULL = inzwischen bekannt -> rejected), dann der Probelauf derselben Anlege-fn
--   (core.fn_dry_run ueber fn_create_recurring_payment bzw. _transfer, gespeicherter Payload + chat_id): lehnt er ab,
--   geht die Zeile mit Grund in rejected und nicht in die Nachrichten. Der Probelauf rollt jeden Write zurueck, deshalb
--   VOLATILE; je Zeile ein Probelauf samt Event-Folds, deshalb die Obergrenze. Der Nachrichtentext entsteht in der Sprache
--   des Empfaengers (fn_recurring_suggestion_text), die Knopf-Daten tragen nur Zeile und Fassung (rsug:ok|no:<id>:<version>,
--   unter 64 Bytes). Schreibt nichts; gestempelt wird nach dem Senden (fn_record_recurring_suggestions_sent).
--   Eingabe p: {chat_id*}.
--   RUECKGABE: {ok:true, items:[{id, version, message, btn_accept, btn_decline, data_ok, data_no, confidence, amount}],
--   rejected:[{id, reason}], more, open_count, sent_before}.
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_get_recurring_suggestion_queue(p jsonb)
RETURNS jsonb LANGUAGE plpgsql VOLATILE AS $$
DECLARE
    v_chat   TEXT := NULLIF(btrim(COALESCE(p->>'chat_id', '')), '');
    v_s      JSONB;
    v_lang   TEXT;
    v_row    RECORD;
    v_items  JSONB := '[]'::jsonb;
    v_rej    JSONB := '[]'::jsonb;
    v_dry    JSONB;
    v_args   JSONB;
    v_cur    TEXT;
    v_left   INT := 0;
    v_empty  JSONB := jsonb_build_object('ok', true, 'items', '[]'::jsonb, 'rejected', '[]'::jsonb, 'more', 0,
                                         'open_count', 0, 'sent_before', 0);
BEGIN
    IF v_chat IS NULL OR v_chat !~ '^-?[0-9]{1,18}$' THEN
        RETURN v_empty;
    END IF;
    v_s := agent.fn_resolve_sender(v_chat::bigint);
    IF v_s->>'role' IS NULL OR v_s->>'role' NOT IN ('owner', 'partner') THEN
        RETURN v_empty;
    END IF;
    v_lang := agent.fn_person_lang(v_s->>'person_id')->>'lang';

    FOR v_row IN
        SELECT q.* FROM (
            SELECT s.id, s.version, s.entity_type, s.payload, finance.fn_recurring_suggestion_measure(s.payload) AS m
            FROM finance.import_staging s
            WHERE s.origin = 'recurring_suggestion' AND s.chat_id = v_chat AND s.status = 'staged'
              AND NOT finance.fn_recurring_suggestion_expired(s.batch_id)
              AND s.sent_version IS DISTINCT FROM s.version) q
        ORDER BY (q.m->>'confidence' = 'sure') DESC NULLS LAST, (q.payload->>'amount')::numeric DESC, q.id
    LOOP
        IF jsonb_array_length(v_items) >= 10 THEN
            v_left := v_left + 1;
            CONTINUE;
        END IF;
        IF v_row.m IS NULL THEN
            v_rej := v_rej || jsonb_build_array(jsonb_build_object('id', v_row.id, 'reason', 'already_known'));
            CONTINUE;
        END IF;
        v_args := finance.fn_recurring_suggestion_args(v_row.payload) || jsonb_build_object('chat_id', v_chat);
        v_dry := CASE WHEN v_row.entity_type = 'recurring_transfer'
                      THEN core.fn_dry_run('finance.fn_create_recurring_transfer(jsonb)'::regprocedure, v_args)
                      ELSE core.fn_dry_run('finance.fn_create_recurring_payment(jsonb)'::regprocedure, v_args) END;
        IF (v_dry->>'ok')::boolean IS DISTINCT FROM true THEN
            v_rej := v_rej || jsonb_build_array(jsonb_build_object('id', v_row.id, 'reason', left(COALESCE(v_dry->>'reason', 'rejected'), 300)));
            CONTINUE;
        END IF;
        SELECT a.currency INTO v_cur FROM finance.accounts a
        WHERE a.id = COALESCE((v_row.payload->>'from_account_id')::int, (v_row.payload->>'account_id')::int);
        v_items := v_items || jsonb_build_array(jsonb_build_object(
            'id', v_row.id, 'version', v_row.version, 'confidence', v_row.m->>'confidence', 'amount', v_row.payload->'amount',
            'message', finance.fn_recurring_suggestion_text('offer', jsonb_build_object(
                'name', v_row.payload->>'name', 'entity_type', v_row.entity_type, 'direction', v_row.payload->>'direction',
                'amount', v_row.payload->'amount', 'currency', v_cur, 'unit', v_row.payload->>'schedule_unit',
                'interval', v_row.payload->'schedule_interval', 'dom', v_row.payload->'schedule_day_of_month',
                'start', v_row.payload->>'first_payment_date',
                'account', COALESCE(v_row.payload->>'from_account', v_row.payload->>'account'), 'to_account', v_row.payload->>'to_account',
                'recurring_kind', v_row.payload->>'recurring_kind', 'origin_kind', v_row.payload->>'origin_kind',
                'confidence', v_row.m->>'confidence', 'rhythm_assumed', v_row.m->'rhythm_assumed'), v_lang),
            'btn_accept', core.fn_ui_text('finance.recurring_suggest.btn_accept', v_lang),
            'btn_decline', core.fn_ui_text('finance.recurring_suggest.btn_decline', v_lang),
            'data_ok', 'rsug:ok:' || v_row.id || ':' || v_row.version,
            'data_no', 'rsug:no:' || v_row.id || ':' || v_row.version));
    END LOOP;

    RETURN jsonb_build_object('ok', true, 'items', v_items, 'rejected', v_rej, 'more', v_left,
        'open_count', (SELECT count(*) FROM finance.import_staging s
                       WHERE s.origin = 'recurring_suggestion' AND s.chat_id = v_chat AND s.status = 'staged'
              AND NOT finance.fn_recurring_suggestion_expired(s.batch_id)),
        'sent_before', (SELECT count(*) FROM finance.import_staging s
                        WHERE s.origin = 'recurring_suggestion' AND s.chat_id = v_chat AND s.status = 'staged'
              AND NOT finance.fn_recurring_suggestion_expired(s.batch_id)
                          AND s.sent_version = s.version));
END;
$$;
