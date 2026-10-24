-- tests/db/career/test_fn_validate_career_profile.sql
-- career.fn_validate_career_profile: Strukturregeln des career_profile-Sidecars (partial-tolerant,
-- owner-scoped). Direkt-Aufruf (NULL = gueltig, sonst Fehlertext).
BEGIN;
DO $$
DECLARE v_err TEXT;
BEGIN
  -- gueltiges Voll-Profil -> NULL
  v_err := career.fn_validate_career_profile(jsonb_build_object(
    'current_title','IT-Projektmanager','industry','Energiewirtschaft','experience_years',10,
    'skills', jsonb_build_array(jsonb_build_object('name','Python','level','expert','years_experience',8)),
    'as_of','2026-06-01'));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [valid]: %', v_err; END IF;

  -- facts optional -> NULL
  IF career.fn_validate_career_profile(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [null facts]'; END IF;
  IF career.fn_validate_career_profile('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [empty facts]'; END IF;

  -- experience_years ausserhalb 0..80
  IF career.fn_validate_career_profile(jsonb_build_object('experience_years',100)) IS NULL THEN
    RAISE EXCEPTION 'FAIL [experience_years range]'; END IF;

  -- ungueltiges Skill-Level
  IF career.fn_validate_career_profile(jsonb_build_object('skills',
       jsonb_build_array(jsonb_build_object('name','X','level','guru')))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [skill level enum]'; END IF;

  -- Skill ohne name
  IF career.fn_validate_career_profile(jsonb_build_object('skills',
       jsonb_build_array(jsonb_build_object('level','expert')))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [skill name required]'; END IF;

  -- as_of in der Zukunft
  IF career.fn_validate_career_profile(jsonb_build_object('as_of', to_char(CURRENT_DATE+1,'YYYY-MM-DD'))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [as_of future]'; END IF;

  -- as_of kein gueltiges Datum
  IF career.fn_validate_career_profile(jsonb_build_object('as_of','not-a-date')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [as_of invalid]'; END IF;

  RAISE NOTICE 'PASS test_fn_validate_career_profile [valid/optional/exp-range/skill-level/skill-name/as_of]';
END $$;
ROLLBACK;
