-- tests/db/career/test_fn_validate_career_planning.sql
-- career.fn_validate_career_planning: Strukturregeln des career_planning-Sidecars (partial-tolerant).
BEGIN;
DO $$
DECLARE v_err TEXT;
BEGIN
  -- gueltiger Plan -> NULL
  v_err := career.fn_validate_career_planning(jsonb_build_object(
    'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master','salary_expectation_eur',75000,'priority',1)),
    'target_industries', jsonb_build_array('Tech','Finance'),
    'timeline_years', 2));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [valid]: %', v_err; END IF;

  -- partial-tolerant: leer/NULL -> NULL
  IF career.fn_validate_career_planning(NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [null]'; END IF;
  IF career.fn_validate_career_planning('{}'::jsonb) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [empty]'; END IF;

  -- target_roles[].title leer
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles',
       jsonb_build_array(jsonb_build_object('title','   ')))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [empty title]'; END IF;

  -- salary ausserhalb sane range
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles',
       jsonb_build_array(jsonb_build_object('title','X','salary_expectation_eur',99999999)))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [salary range]'; END IF;

  -- timeline_years ausserhalb 0..15
  IF career.fn_validate_career_planning(jsonb_build_object('timeline_years',20)) IS NULL THEN
    RAISE EXCEPTION 'FAIL [timeline range]'; END IF;

  -- target_industries kein Array
  IF career.fn_validate_career_planning(jsonb_build_object('target_industries','tech')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [industries type]'; END IF;

  -- WS-2 Suchkriterien (targets-Block): gueltig -> NULL
  v_err := career.fn_validate_career_planning(jsonb_build_object(
    'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master')),
    'target_locations', jsonb_build_array('Hamburg','Bremen'),
    'search_radius_km', 50,
    'employment_types', jsonb_build_array('vollzeit')));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [search valid]: %', v_err; END IF;

  -- target_locations kein Array
  IF career.fn_validate_career_planning(jsonb_build_object('target_locations','Hamburg')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [locations type]'; END IF;

  -- search_radius_km out of range
  IF career.fn_validate_career_planning(jsonb_build_object('search_radius_km',1000)) IS NULL THEN
    RAISE EXCEPTION 'FAIL [radius range]'; END IF;

  -- employment_types kein Array
  IF career.fn_validate_career_planning(jsonb_build_object('employment_types','vollzeit')) IS NULL THEN
    RAISE EXCEPTION 'FAIL [employment type]'; END IF;

  -- WS-3 required_skills: gueltig (min_level optional, is_blocker optional) -> NULL
  v_err := career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','Scrum Master','required_skills', jsonb_build_array(
      jsonb_build_object('name','Scrum','min_level','advanced','is_blocker',true),
      jsonb_build_object('name','Python'))))));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [required_skills valid]: %', v_err; END IF;

  -- required_skills kein Array
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','X','required_skills','Scrum')))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [required_skills array]'; END IF;

  -- required_skills[].name leer
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','X','required_skills', jsonb_build_array(jsonb_build_object('name','  ')))))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [required_skills name]'; END IF;

  -- ungueltiges min_level (via fn_skill_level_rank=0)
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','X','required_skills', jsonb_build_array(
      jsonb_build_object('name','Scrum','min_level','guru')))))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [required_skills min_level enum]'; END IF;

  -- doppelter Skill-Name je Rolle (case-insensitiv)
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','X','required_skills', jsonb_build_array(
      jsonb_build_object('name','Scrum'), jsonb_build_object('name','scrum')))))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [required_skills dup per role]'; END IF;

  -- is_blocker kein bool
  IF career.fn_validate_career_planning(jsonb_build_object('target_roles', jsonb_build_array(
    jsonb_build_object('title','X','required_skills', jsonb_build_array(
      jsonb_build_object('name','Scrum','is_blocker','maybe')))))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [required_skills is_blocker bool]'; END IF;

  -- WS-5 transition-Block (Runway-Szenario): probation_months/expected_gap_income_eur, beide optional/roh -> NULL
  v_err := career.fn_validate_career_planning(jsonb_build_object(
    'transition', jsonb_build_object('probation_months', 6, 'expected_gap_income_eur', 1800)));
  IF v_err IS NOT NULL THEN RAISE EXCEPTION 'FAIL [transition valid]: %', v_err; END IF;
  -- probation_months keine Zahl
  IF career.fn_validate_career_planning(jsonb_build_object('transition', jsonb_build_object('probation_months','sechs'))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [transition probation type]'; END IF;
  -- probation_months out of range (0..24)
  IF career.fn_validate_career_planning(jsonb_build_object('transition', jsonb_build_object('probation_months',36))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [transition probation range]'; END IF;
  -- expected_gap_income_eur out of range (0..1000000)
  IF career.fn_validate_career_planning(jsonb_build_object('transition', jsonb_build_object('expected_gap_income_eur',-5))) IS NULL THEN
    RAISE EXCEPTION 'FAIL [transition gap income range]'; END IF;

  -- WS-5 Core-Denylist (agent.fn_validate_household_facts, generisch + rekursiv je facts-Sidecar):
  -- abgeleitete Runway-Werte duerfen NIE gespeichert werden (render-at-fetch); die ROH-Szenario-Fakten schon.
  IF agent.fn_validate_household_facts(jsonb_build_object('runway_months', 8), 'career_planning') IS NULL THEN
    RAISE EXCEPTION 'FAIL [denylist runway_months]'; END IF;
  IF agent.fn_validate_household_facts(jsonb_build_object('transition', jsonb_build_object('runway', 8)), 'career_planning') IS NULL THEN
    RAISE EXCEPTION 'FAIL [denylist nested transition.runway]'; END IF;
  IF agent.fn_validate_household_facts(
       jsonb_build_object('transition', jsonb_build_object('probation_months', 6, 'expected_gap_income_eur', 1800)),
       'career_planning') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [denylist erlaubt rohe probation_months/expected_gap_income_eur]'; END IF;

  RAISE NOTICE 'PASS test_fn_validate_career_planning [valid/optional/title/salary/timeline/industries/search-criteria/required_skills/transition+denylist]';
END $$;
ROLLBACK;
