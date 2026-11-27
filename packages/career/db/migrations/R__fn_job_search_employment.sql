-- ============================================================
-- career.fn_job_search_employment (READ-ONLY, IMMUTABLE — Arbeitszeit-Filter je Job-Quelle)
--   Uebersetzt career_planning.employment_types (vollzeit|teilzeit, Schreibweise egal) in die Such-Parameter des
--   werktaeglichen Scans cron.score_jobs.
--   Eingabe: p_planning (career_planning-Fakten, NULL erlaubt).
--   Rueckgabe jsonb, jeder Key nur wenn ein Filter gilt (sonst {} = so breit wie ohne Angabe):
--     ba_arbeitszeit ('vz', 'tz' oder 'vz;tz' — Bundesagentur Jobsuche, Parameter arbeitszeit),
--     adzuna_param ('full_time' | 'part_time' — Adzuna kennt nur je ein Flag =1; beide Arten -> kein Filter),
--     jsearch_employment_types ('FULLTIME', 'PARTTIME' oder 'FULLTIME,PARTTIME').
--   Unbekannte Werte werden ignoriert (der Validator laesst sie bewusst zu, alte Plaene bleiben gueltig); ohne
--   bekannten Wert und bei Nicht-Arrays gilt kein Filter.
--   Tests: tests/db/career/test_fn_job_search_employment.sql
-- ============================================================
CREATE OR REPLACE FUNCTION career.fn_job_search_employment(p_planning jsonb)
RETURNS jsonb LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE
    v_full boolean := false;
    v_part boolean := false;
BEGIN
    IF jsonb_typeof(p_planning->'employment_types') = 'array' THEN
        SELECT COALESCE(bool_or(lower(btrim(e #>> '{}')) = 'vollzeit'), false),
               COALESCE(bool_or(lower(btrim(e #>> '{}')) = 'teilzeit'), false)
          INTO v_full, v_part
          FROM jsonb_array_elements(p_planning->'employment_types') e
         WHERE jsonb_typeof(e) = 'string';
    END IF;
    IF NOT (v_full OR v_part) THEN
        RETURN '{}'::jsonb;
    END IF;
    RETURN jsonb_strip_nulls(jsonb_build_object(
        'ba_arbeitszeit', concat_ws(';', CASE WHEN v_full THEN 'vz' END, CASE WHEN v_part THEN 'tz' END),
        'adzuna_param', CASE WHEN v_full AND NOT v_part THEN 'full_time'
                             WHEN v_part AND NOT v_full THEN 'part_time' END,
        'jsearch_employment_types', concat_ws(',', CASE WHEN v_full THEN 'FULLTIME' END, CASE WHEN v_part THEN 'PARTTIME' END)));
END;
$$;
