-- tests/db/career/test_fn_job_search_employment.sql
-- career.fn_job_search_employment: employment_types aus career_planning -> Filter je Job-Quelle (Bundesagentur
--   arbeitszeit vz/tz mit ';', Adzuna nur bei genau einer Art, JSearch FULLTIME/PARTTIME mit ','). Leer/fehlend oder
--   beide Arten bei Adzuna -> kein Key ({} = kein Filter) (die Suche bleibt so breit wie vorher).
BEGIN;

DO $$
DECLARE v jsonb;
BEGIN
  v := career.fn_job_search_employment(jsonb_build_object('employment_types', jsonb_build_array('vollzeit')));
  IF v->>'ba_arbeitszeit' IS DISTINCT FROM 'vz' OR v->>'adzuna_param' IS DISTINCT FROM 'full_time'
     OR v->>'jsearch_employment_types' IS DISTINCT FROM 'FULLTIME' THEN
    RAISE EXCEPTION 'FAIL [nur vollzeit]: %', v; END IF;

  v := career.fn_job_search_employment(jsonb_build_object('employment_types', jsonb_build_array(' Teilzeit ')));
  IF v->>'ba_arbeitszeit' IS DISTINCT FROM 'tz' OR v->>'adzuna_param' IS DISTINCT FROM 'part_time'
     OR v->>'jsearch_employment_types' IS DISTINCT FROM 'PARTTIME' THEN
    RAISE EXCEPTION 'FAIL [nur teilzeit, Schreibweise]: %', v; END IF;

  v := career.fn_job_search_employment(jsonb_build_object('employment_types', jsonb_build_array('teilzeit','vollzeit','vollzeit')));
  IF v->>'ba_arbeitszeit' IS DISTINCT FROM 'vz;tz' OR v ? 'adzuna_param'
     OR v->>'jsearch_employment_types' IS DISTINCT FROM 'FULLTIME,PARTTIME' THEN
    RAISE EXCEPTION 'FAIL [beide Arten]: %', v; END IF;

  v := career.fn_job_search_employment(jsonb_build_object('target_locations', jsonb_build_array('Leipzig')));
  IF v IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [ohne employment_types]: %', v; END IF;
  v := career.fn_job_search_employment(NULL);
  IF v IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [NULL-Plan]: %', v; END IF;
  v := career.fn_job_search_employment(jsonb_build_object('employment_types', 'vollzeit'));
  IF v IS DISTINCT FROM '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [kein Array -> kein Filter]: %', v; END IF;

  RAISE NOTICE 'PASS career.fn_job_search_employment [vollzeit, teilzeit, beide, leer, NULL, kein Array]';
END $$;

ROLLBACK;
