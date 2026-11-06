-- tests/db/career/test_fn_validate_career_preferences.sql
-- career.fn_validate_career_preferences: Strukturregeln des career_preferences-Sidecars (partial-tolerant).
BEGIN;
DO $$ DECLARE v_err TEXT; BEGIN
  -- gueltig -> NULL
  v_err := career.fn_validate_career_preferences(jsonb_build_object(
    'preferred_aspects', jsonb_build_array('Remote-Anteil','Agile Kultur'),
    'disliked_aspects', jsonb_build_array('viel Reise'),
    'disliked_industries', jsonb_build_array('Ruestung'),
    'salary_floor', 70000, 'remote_preference','hybrid', 'commute_max_km', 40));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [valid]: %', v_err; END IF;

  -- partial-tolerant: NULL/leer -> NULL
  IF career.fn_validate_career_preferences(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [null]'; END IF;
  IF career.fn_validate_career_preferences('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [empty]'; END IF;

  -- array-Feld kein Array
  IF career.fn_validate_career_preferences(jsonb_build_object('preferred_aspects','remote')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [array type]'; END IF;

  -- salary_floor kein Number
  IF career.fn_validate_career_preferences(jsonb_build_object('salary_floor','viel')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [salary type]'; END IF;

  -- remote_preference ungueltiges ENUM
  IF career.fn_validate_career_preferences(jsonb_build_object('remote_preference','mond')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [remote enum]'; END IF;

  -- commute_max_km out of range
  IF career.fn_validate_career_preferences(jsonb_build_object('commute_max_km',5000)) IS NULL THEN
    RAISE EXCEPTION 'FAIL [commute range]'; END IF;

  RAISE NOTICE 'PASS test_fn_validate_career_preferences [valid/optional/array/salary/remote/commute]';
END $$;
ROLLBACK;
