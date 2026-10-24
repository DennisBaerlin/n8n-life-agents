-- ============================================================
-- fn_import_validate (Dry-Run je Row — schreibt NUR status/validation_error im Staging)
--   Prueft jede nicht-committete Row eines Batches via fn_import_validate_row (per-Row-Logik:
--   Pflichtfelder je entity_type, Enum-/Zahlen-/Datums-Casts, Dubletten-Backstop, Referenzen).
--   Domaenen-Writes passieren hier NIE; die tiefen Wert-Guards der fn_create_*/fn_book_*
--   greifen zusaetzlich beim Commit (fn_import_bundle sammelt deren {ok:false} und rollt
--   alles zurueck).
--   RUECKGABE: {ok:true, total, valid, invalid, errors:[{row_no, entity_type, error, row}]}
--   row = die Kennfelder der ungueltigen Zeile (Allow-List, nicht der volle Payload: Dokument-Text ist untrusted),
--   damit der Agent gezielt nach dem Fehlenden fragt statt nach Werten, die im Dokument stehen (Owner 2026-10-23).
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_validate(p_batch_id uuid)
RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE
    v_row     RECORD;
    v_err     TEXT;
    v_errors  JSONB := '[]'::jsonb;
    v_total   INT := 0;
    v_valid   INT := 0;
BEGIN
    FOR v_row IN
        SELECT * FROM finance.import_staging
        WHERE batch_id = p_batch_id AND status <> 'committed'
        ORDER BY row_no
        FOR UPDATE
    LOOP
        v_total := v_total + 1;
        v_err := finance.fn_import_validate_row(p_batch_id, v_row.row_no, v_row.entity_type, v_row.payload);

        IF v_err IS NULL THEN
            v_valid := v_valid + 1;
            UPDATE finance.import_staging
            SET status = 'valid', validation_error = NULL
            WHERE id = v_row.id;
        ELSE
            v_errors := v_errors || jsonb_build_object('row_no', v_row.row_no, 'entity_type', v_row.entity_type,
                'error', v_err,
                'row', (SELECT COALESCE(jsonb_object_agg(e.key, e.value), '{}'::jsonb) FROM jsonb_each(v_row.payload) e
                        WHERE e.key IN ('name','isin','symbol','shares','depot','depot_number','depot_holder',
                                        'account_type','account_number')));
            UPDATE finance.import_staging
            SET status = 'invalid', validation_error = v_err
            WHERE id = v_row.id;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', true, 'total', v_total, 'valid', v_valid,
        'invalid', v_total - v_valid, 'errors', v_errors);
END;
$$;
