-- ============================================================
-- fn_import_update_row (Korrektur VOR dem Gate — KEIN HITL: Staging ist keine Domaenen-Daten)
--   "Zeile 7: Saldo 5.230" -> Key-Merge in den Row-Payload + Revalidate des Batches.
--   Payload p: { batch_id, row_no, payload_merge (opt: Keys mergen; null-Wert = Key entfernen),
--                delete_row (opt true: Row entfernen) }
--   RUECKGABE: {ok:true, row_no, status, validation_error, valid, invalid} |
--              {ok:false, reason} (Row fehlt, Batch committed, nichts zu tun, Phase B: batch_id/row_no/
--              payload_merge formal ungueltig — Modell-Eingabe, vorher RAISEte der DECLARE-Cast)
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_update_row(p jsonb)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_batch   UUID;
    v_row_no  INT;
    v_row     finance.import_staging%ROWTYPE;
    v_payload JSONB;
    v_key     TEXT;
    v_summary JSONB;
    v_status  TEXT;
    v_err     TEXT;
BEGIN
    IF COALESCE(p->>'batch_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('batch_id must be the UUID returned by tool_import_stage_rows, got %L', p->>'batch_id'));
    END IF;
    IF COALESCE(p->>'row_no', '') !~ '^\s*[0-9]{1,9}\s*$' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('row_no must be a positive whole number, got %L', p->>'row_no'));
    END IF;
    v_batch  := (p->>'batch_id')::uuid;
    v_row_no := trim(p->>'row_no')::int;

    SELECT * INTO v_row FROM finance.import_staging
    WHERE batch_id = v_batch AND row_no = v_row_no
    FOR UPDATE;
    IF NOT FOUND THEN
        RETURN jsonb_build_object('ok', false,
            'reason', format('row %s not found in this batch', v_row_no));
    END IF;
    IF v_row.status = 'committed' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'row is already committed');
    END IF;

    IF COALESCE((p->>'delete_row')::boolean, false) THEN
        DELETE FROM finance.import_staging WHERE id = v_row.id;
        v_summary := finance.fn_import_validate(v_batch);
        RETURN jsonb_build_object('ok', true, 'deleted_row', v_row_no,
            'valid', v_summary->'valid', 'invalid', v_summary->'invalid');
    END IF;

    IF jsonb_typeof(p->'payload_merge') IS DISTINCT FROM 'object' THEN
        RETURN jsonb_build_object('ok', false,
            'reason', 'provide payload_merge (object) or delete_row=true');
    END IF;

    -- Merge; explizites null entfernt den Key ("Feld doch leer lassen")
    v_payload := v_row.payload;
    FOR v_key IN SELECT k FROM jsonb_object_keys(p->'payload_merge') k LOOP
        IF jsonb_typeof(p->'payload_merge'->v_key) = 'null' THEN
            v_payload := v_payload - v_key;
        ELSE
            v_payload := jsonb_set(v_payload, ARRAY[v_key], p->'payload_merge'->v_key);
        END IF;
    END LOOP;

    -- Zahl-Felder wieder kanonisieren (gleiche EINE Stelle wie beim Stage-Insert; eine Korrektur
    -- "Zeile 7: Saldo 5.230,50" wird genauso normalisiert wie der Erst-Import).
    v_payload := finance.fn_import_normalize_payload(v_row.entity_type, v_payload);

    UPDATE finance.import_staging SET payload = v_payload WHERE id = v_row.id;

    v_summary := finance.fn_import_validate(v_batch);
    SELECT status, validation_error INTO v_status, v_err
    FROM finance.import_staging WHERE id = v_row.id;

    RETURN jsonb_build_object('ok', true, 'row_no', v_row_no,
        'status', v_status, 'validation_error', v_err,
        'valid', v_summary->'valid', 'invalid', v_summary->'invalid');
END;
$$;
