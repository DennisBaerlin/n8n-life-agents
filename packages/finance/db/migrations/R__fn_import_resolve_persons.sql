-- ============================================================
-- fn_import_resolve_persons (read-only) — Personen-Feld einer Import-Zeile wie im Einzel-Tool aufloesen
--   Je entity_type genau EIN Personen-Feld (gleiche Namen wie die create_*-Tools):
--     account/real_estate/pension -> owner_person, insurance -> policyholder_person,
--     loan -> borrower_person, savings_goal -> beneficiary_person; alle anderen Typen: keins.
--   Der Name wird ueber core.fn_resolve_person (publiziertes DEFINER-Fenster, unter finance_rw aufrufbar)
--   zum Slug aufgeloest und als <feld>_id in den Payload gelegt — genau das Feld, das die fn_create_* lesen.
--   Leer = Haushalt (kein Feld). Fremde/alte Personen-Keys (owner, account_holder, policyholder, borrower,
--   holder, *_person_id, ein *_person-Feld eines anderen Typs) wurden frueher still verworfen -> jetzt ein
--   klarer Zeilenfehler. Genutzt von fn_import_validate_row (Fehler frueh, vor dem Gate) UND fn_import_bundle
--   (erneute Aufloesung beim Commit: kein TOCTOU zwischen Validate und Write).
--   RUECKGABE: {payload: <aufgeloester Payload>, error: <EN-Text|null>}
-- ============================================================
CREATE OR REPLACE FUNCTION finance.fn_import_resolve_persons(p_type text, p jsonb)
RETURNS jsonb LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_field TEXT := finance.fn_import_person_field(p_type);
    v_key   TEXT;
    v_name  TEXT;
    v_id    TEXT;
    v_hits  INT;
BEGIN
    SELECT k INTO v_key FROM jsonb_object_keys(p) k
    WHERE lower(k) IN ('owner', 'account_holder', 'policyholder', 'borrower', 'holder')
       OR k LIKE '%\_person\_id'
       OR (k LIKE '%\_person' AND k IS DISTINCT FROM v_field)
    LIMIT 1;
    IF v_key IS NOT NULL THEN
        RETURN jsonb_build_object('payload', p, 'error', CASE
            WHEN v_field IS NULL THEN format('key "%s" is not supported for %s rows (this type has no person)', v_key, p_type)
            ELSE format('key "%s" is not supported - name the person in "%s" (first and last name), or leave it empty for the household', v_key, v_field)
        END);
    END IF;

    v_name := NULLIF(trim(COALESCE(p->>v_field, '')), '');
    IF v_field IS NULL OR v_name IS NULL THEN
        RETURN jsonb_build_object('payload', CASE WHEN v_field IS NULL THEN p ELSE p - v_field END, 'error', NULL);
    END IF;

    SELECT r.person_id, r.hit_count INTO v_id, v_hits FROM core.fn_resolve_person(v_name) r;
    IF v_hits IS DISTINCT FROM 1 THEN
        RETURN jsonb_build_object('payload', p, 'error',
            format('%s "%s" matches %s household members - use the exact first and last name, or leave it empty for the household',
                   v_field, v_name, COALESCE(v_hits, 0)));
    END IF;
    RETURN jsonb_build_object('payload', (p - v_field) || jsonb_build_object(v_field || '_id', v_id), 'error', NULL);
END;
$$;
