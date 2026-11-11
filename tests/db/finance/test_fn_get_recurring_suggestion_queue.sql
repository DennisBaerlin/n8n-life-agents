-- ============================================================
-- test_fn_get_recurring_suggestion_queue -- Versandliste der Vorschlags-Nachrichten (erfundene Werte)
--   Q1 Kind und Unbekannte bekommen nichts; Q2 12 offene -> 10 Nachrichten + more 2, sure zuerst, dann Betrag;
--   Q3 Vorschau = Probelauf der Anlege-fn, danach nichts in der DB; Q4 Knopf-Daten <= 64 Bytes; Q5 Probelauf lehnt ab
--   (gleichnamige Zahlung) -> rejected; Q6 nur Ungesendetes, eine neue Fassung kommt wieder; Q7 fremder Chat nie.
--   Zusammen mit test_fn_record_recurring_suggestions_sent (Stempel) und dem Handler-Test.
-- ============================================================
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'rq', NULL, 'lazy', 'x', jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','__rq_o__','first_name','Olli','last_name','Muster','role','owner','birth_date','1980-01-01','telegram_user_id',7801,'as_of','2026-10-23'),
    jsonb_build_object('person_id','__rq_k__','first_name','Kim','last_name','Muster','role','child','birth_date','2012-01-01','telegram_user_id',7803,'as_of','2026-10-23')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

CREATE FUNCTION pg_temp.row(p_batch uuid, p_no int, p_chat text, p_acct int, p_name text, p_amt numeric, p_n int)
RETURNS int LANGUAGE sql AS $$
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, status, source, origin, chat_id, version, merged_at)
    SELECT p_batch, p_no, 'recurring_payment', jsonb_build_object('name', p_name, 'series', p_name, 'account_id', p_acct,
               'account', '__t_rq_giro__', 'direction', 'expense', 'amount', p_amt, 'schedule_unit', 'month', 'schedule_interval', 1,
               'schedule_day_of_month', 5, 'first_payment_date', (date_trunc('month', core.fn_today()) + interval '1 month 4 days')::date,
               'recurring_kind', 'subscription', 'rhythm_hint', 'monthly', 'origin_kind', 'statement',
               'occurrences', (SELECT jsonb_agg(jsonb_build_object('date', (date_trunc('month', core.fn_today()) - make_interval(months => g) + interval '4 days')::date,
                                   'amount', -p_amt, 'account_id', p_acct) ORDER BY g)
                               FROM generate_series(0, p_n - 1) g)),
           'staged', 'vision', 'recurring_suggestion', p_chat, 1, now()
    RETURNING id;
$$;

DO $$
DECLARE
    T      DATE := core.fn_today();
    v_acct INT;
    v_b    UUID := gen_random_uuid();
    v_q    JSONB;
    v_ids  INT[] := '{}';
    v_rp   INT;
    v_cnt  INT;
    k      INT;
BEGIN
    DELETE FROM finance.import_staging;
    v_acct := (finance.fn_create_account(jsonb_build_object('name', '__t_rq_giro__', 'account_type', 'cash', 'currency', 'EUR',
                 'bank', 'Testbank', 'opening_balance', 1000, 'opening_balance_date', (T - 200)::text))->>'account_id')::int;
    -- 2 sichere (3 Termine) mit kleinem Betrag, 10 unsichere (1 Termin) mit groesserem
    v_ids := v_ids || pg_temp.row(v_b, 1, '7801', v_acct, 'Sicher Eins', 5, 3) || pg_temp.row(v_b, 2, '7801', v_acct, 'Sicher Zwei', 6, 3);
    FOR k IN 1..10 LOOP
        v_ids := v_ids || pg_temp.row(v_b, 2 + k, '7801', v_acct, 'Vorschlag ' || chr(64 + k), 100 + k, 1);
    END LOOP;
    PERFORM pg_temp.row(gen_random_uuid(), 1, '7803', v_acct, 'Kind Vorschlag', 9, 1);

    -- Q1
    IF jsonb_array_length(finance.fn_get_recurring_suggestion_queue('{"chat_id":"7803"}')->'items') <> 0
       OR jsonb_array_length(finance.fn_get_recurring_suggestion_queue('{"chat_id":"999"}')->'items') <> 0
       OR jsonb_array_length(finance.fn_get_recurring_suggestion_queue('{"chat_id":"x"}')->'items') <> 0 THEN
        RAISE EXCEPTION 'FAIL [Q1 Kind/Unbekannt leer]';
    END IF;

    -- Q2/Q3/Q4
    SELECT count(*) INTO v_cnt FROM finance.recurring_payments;
    v_q := finance.fn_get_recurring_suggestion_queue('{"chat_id":"7801"}');
    IF jsonb_array_length(v_q->'items') <> 10 OR (v_q->>'more')::int <> 2 OR (v_q->>'open_count')::int <> 12
       OR jsonb_array_length(v_q->'rejected') <> 0 THEN
        RAISE EXCEPTION 'FAIL [Q2 10 + more 2]: %', v_q;
    END IF;
    IF v_q->'items'->0->>'confidence' <> 'sure' OR v_q->'items'->1->>'confidence' <> 'sure'
       OR (v_q->'items'->0->>'amount')::numeric <> 6 OR (v_q->'items'->2->>'amount')::numeric <> 110 THEN
        RAISE EXCEPTION 'FAIL [Q2 sure zuerst, dann Betrag]: %', v_q->'items';
    END IF;
    IF (SELECT count(*) FROM finance.recurring_payments) <> v_cnt THEN
        RAISE EXCEPTION 'FAIL [Q3 Probelauf hinterlaesst nichts]';
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_q->'items') i
               WHERE octet_length(i->>'data_ok') > 64 OR octet_length(i->>'data_no') > 64
                  OR i->>'data_ok' <> 'rsug:ok:' || (i->>'id') || ':1' OR i->>'data_no' <> 'rsug:no:' || (i->>'id') || ':1'
                  OR NULLIF(i->>'message', '') IS NULL) OR position('Sicher Zwei' IN v_q->'items'->0->>'message') = 0 THEN
        RAISE EXCEPTION 'FAIL [Q4 Knopf-Daten/Text]: %', v_q->'items';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_q->'items') i WHERE i->>'message' LIKE '%Vorschlag J%') THEN
        RAISE EXCEPTION 'FAIL [Q2 groesster unsicherer dabei]: %', v_q->'items';
    END IF;

    -- Q5 gleichnamige Zahlung angelegt -> Probelauf lehnt ab
    PERFORM finance.fn_create_recurring_payment(jsonb_build_object('name', 'Vorschlag J', 'account_id', v_acct, 'direction', 'expense',
                 'amount', 3, 'schedule_unit', 'month', 'schedule_day_of_month', 20, 'first_payment_date', (T - 100)::text));
    v_q := finance.fn_get_recurring_suggestion_queue('{"chat_id":"7801"}');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_q->'rejected') r WHERE (r->>'id')::int = v_ids[12])
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_q->'items') i WHERE (i->>'id')::int = v_ids[12])
       OR jsonb_array_length(v_q->'items') <> 10 OR (v_q->>'more')::int <> 1 THEN
        RAISE EXCEPTION 'FAIL [Q5 Probelauf-Ablehnung]: %', v_q;
    END IF;

    -- Q6 gestempelt -> weg; neue Fassung -> wieder da
    PERFORM finance.fn_record_recurring_suggestions_sent(jsonb_build_object('chat_id', '7801',
        'sent', (SELECT jsonb_agg(jsonb_build_object('id', i->'id', 'version', i->'version')) FROM jsonb_array_elements(v_q->'items') i),
        'rejected', v_q->'rejected'));
    v_q := finance.fn_get_recurring_suggestion_queue('{"chat_id":"7801"}');
    IF jsonb_array_length(v_q->'items') <> 1 OR (v_q->>'sent_before')::int <> 10 OR (v_q->>'open_count')::int <> 11 THEN
        RAISE EXCEPTION 'FAIL [Q6 nur Ungesendetes]: %', v_q;
    END IF;
    UPDATE finance.import_staging SET version = version + 1 WHERE id = v_ids[1];
    v_q := finance.fn_get_recurring_suggestion_queue('{"chat_id":"7801"}');
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_q->'items') i WHERE (i->>'id')::int = v_ids[1] AND i->>'data_ok' LIKE '%:2') THEN
        RAISE EXCEPTION 'FAIL [Q6 neue Fassung kommt neu]: %', v_q;
    END IF;
    -- Q7 Stapel seit mehr als 7 Tagen nicht ergaenzt, aber (noch) nicht geloescht -> abgelaufen, nichts mehr senden
    UPDATE finance.import_staging SET merged_at = now() - interval '8 days' WHERE batch_id = v_b;
    v_q := finance.fn_get_recurring_suggestion_queue('{"chat_id":"7801"}');
    IF jsonb_array_length(v_q->'items') <> 0 OR jsonb_array_length(v_q->'rejected') <> 0 OR (v_q->>'more')::int <> 0
       OR (v_q->>'open_count')::int <> 0 OR NOT EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_b) THEN
        RAISE EXCEPTION 'FAIL [Q7 abgelaufener Stapel wird nicht gesendet]: %', v_q;
    END IF;
    RAISE NOTICE 'PASS [Q1-Q7 fn_get_recurring_suggestion_queue]';
END $$;
ROLLBACK;
