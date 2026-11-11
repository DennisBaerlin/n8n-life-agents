-- ============================================================
-- test_fn_record_recurring_suggestions_sent -- Versand stempeln: sent_version, rejected -> declined, idempotent,
--   alte Fassung und fremder Chat werden nicht gestempelt
-- ============================================================
BEGIN;
DO $$
DECLARE
    v_b  UUID := gen_random_uuid();
    v_a  INT; v_c INT; v_d INT; v_x INT;
    v_r  JSONB;
BEGIN
    DELETE FROM finance.import_staging;
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, origin, chat_id, version, merged_at)
    VALUES (v_b, 1, 'recurring_payment', '{"name":"A"}', 'recurring_suggestion', '7901', 1, now()) RETURNING id INTO v_a;
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, origin, chat_id, version, merged_at)
    VALUES (v_b, 2, 'recurring_payment', '{"name":"C"}', 'recurring_suggestion', '7901', 2, now()) RETURNING id INTO v_c;
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, origin, chat_id, version, merged_at)
    VALUES (v_b, 3, 'recurring_payment', '{"name":"D"}', 'recurring_suggestion', '7901', 1, now()) RETURNING id INTO v_d;
    INSERT INTO finance.import_staging (batch_id, row_no, entity_type, payload, origin, chat_id, version, merged_at)
    VALUES (gen_random_uuid(), 1, 'recurring_payment', '{"name":"X"}', 'recurring_suggestion', '7999', 1, now()) RETURNING id INTO v_x;

    v_r := finance.fn_record_recurring_suggestions_sent(jsonb_build_object('chat_id', '7901',
               'sent', jsonb_build_array(jsonb_build_object('id', v_a, 'version', 1), jsonb_build_object('id', v_c, 'version', 1),
                                         jsonb_build_object('id', v_x, 'version', 1)),
               'rejected', jsonb_build_array(jsonb_build_object('id', v_d, 'reason', 'name taken'))));
    IF (v_r->>'stamped')::int <> 1 OR (v_r->>'declined')::int <> 1 THEN RAISE EXCEPTION 'FAIL [Zaehler]: %', v_r; END IF;
    IF (SELECT sent_version FROM finance.import_staging WHERE id = v_a) IS DISTINCT FROM 1
       OR (SELECT sent_version FROM finance.import_staging WHERE id = v_c) IS NOT NULL
       OR (SELECT sent_version FROM finance.import_staging WHERE id = v_x) IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL [nur passende Fassung im eigenen Chat gestempelt]';
    END IF;
    IF (SELECT status || '|' || validation_error FROM finance.import_staging WHERE id = v_d) <> 'declined|name taken' THEN
        RAISE EXCEPTION 'FAIL [rejected -> declined mit Grund]';
    END IF;
    v_r := finance.fn_record_recurring_suggestions_sent(jsonb_build_object('chat_id', '7901',
               'sent', jsonb_build_array(jsonb_build_object('id', v_a, 'version', 1))));
    IF (v_r->>'stamped')::int <> 0 OR (SELECT sent_version FROM finance.import_staging WHERE id = v_a) <> 1 THEN
        RAISE EXCEPTION 'FAIL [idempotent]: %', v_r;
    END IF;
    IF (finance.fn_record_recurring_suggestions_sent('{}'::jsonb)->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL [leer]';
    END IF;
    BEGIN
        UPDATE finance.import_staging SET status = 'verworfen' WHERE id = v_a;
        RAISE EXCEPTION 'FAIL [Status-CHECK laesst Fremdwert zu]';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    BEGIN
        INSERT INTO finance.import_staging (batch_id, row_no, entity_type, origin) VALUES (gen_random_uuid(), 1, 'recurring_payment', 'recurring_suggestion');
        RAISE EXCEPTION 'FAIL [origin ohne chat_id]';
    EXCEPTION WHEN check_violation THEN NULL;
    END;
    RAISE NOTICE 'PASS [fn_record_recurring_suggestions_sent + Status-/origin-CHECK]';
END $$;
ROLLBACK;
