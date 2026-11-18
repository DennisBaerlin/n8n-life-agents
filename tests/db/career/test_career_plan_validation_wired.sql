-- tests/db/career/test_career_plan_validation_wired.sql
-- Der Karriere-Plan (per_user: career_planning__<pid>) wird ueber den Berater-Eintrag geprueft (advisors.career.plan_validate_fn),
-- nicht mehr ueber eine context_validators-Zeile: ein einziger Weg fuer Plan-Pruefungen. Echter Speicher-Weg
-- fn_advisor_save_section -> fn_advisor_publish_plan mit chat_id der Person. db_test seedet die Registries nicht -> der Test legt
-- Berater-Eintrag und Scope-Zeile selbst an, wie der Seed sie aus dem Manifest schreibt. Alle Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_res JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, managed_by, package)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11')))),
    'agent','core')
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('career', 'career_planning', 'career.fn_advisor_review', 'career');
  EXECUTE $q$UPDATE core.advisors SET plan_validate_fn = 'career.fn_validate_career_planning' WHERE domain = 'career'$q$;
  IF EXISTS (SELECT 1 FROM core.context_validators WHERE context_name = 'career_planning') THEN
    RAISE EXCEPTION 'FAIL [setup]: career_planning darf keine context_validators-Zeile haben'; END IF;

  -- ungueltig: Gehalts-Einheit ausserhalb des Wertevorrats -> abgelehnt, Draft bleibt, kein Plan-Dokument
  v_res := agent.fn_advisor_save_section(jsonb_build_object('domain','career','chat_id','111','plan_name','__test_career__',
    'section_key','s1','section_content','x','section_data', jsonb_build_object('target_roles', jsonb_build_array(
      jsonb_build_object('title','Data Analyst','salary_expectation_eur',5000,'salary_period','week')))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [setup]: save_section %', v_res; END IF;
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','career','chat_id','111','plan_md','# Plan'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE 'plan facts invalid:%' THEN
    RAISE EXCEPTION 'FAIL [career ungueltig]: erwartet ok:false "plan facts invalid", got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name LIKE 'career_planning%') THEN
    RAISE EXCEPTION 'FAIL [career ungueltig]: Plan-Dokument trotz Ablehnung geschrieben'; END IF;
  RAISE NOTICE 'PASS [Karriere-Plan: ungueltiger Plan ueber den Berater-Eintrag abgelehnt]';

  -- Trigger-Netz fuer die per_user-Zeile: Meldung traegt keinen Wert (nur den Basisnamen)
  BEGIN
    INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, managed_by, package)
    VALUES ('career_planning__erika','t',NULL,'lazy','p',
      jsonb_build_object('facts', jsonb_build_object('target_roles', jsonb_build_array(
        jsonb_build_object('title','Data Analyst','salary_expectation_eur',5000,'salary_period','week')))),'agent','career');
    RAISE EXCEPTION 'FAIL [career Trigger]: ungueltige Fakten per INSERT akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [Karriere-Plan: Trigger-Netz lehnt ab]';
  END;

  -- Mitglied (own_user_only) mit ungueltigem eigenem Plan: gleiche Ablehnung, kein Write fuer seine Zeile
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
      (metadata->'facts'->'persons') || jsonb_build_array(jsonb_build_object('person_id','lena','first_name','Lena','last_name','B',
        'role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))
   WHERE name = 'family';
  v_res := agent.fn_advisor_save_section(jsonb_build_object('domain','career','chat_id','222','plan_name','__test_career_m__',
    'section_key','s1','section_content','x','section_data', jsonb_build_object('target_roles', jsonb_build_array(
      jsonb_build_object('title','Data Analyst','salary_expectation_eur',5000,'salary_basis','netto')))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [setup Mitglied]: save_section %', v_res; END IF;
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','career','chat_id','222','plan_md','# Plan'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE 'plan facts invalid:%' THEN
    RAISE EXCEPTION 'FAIL [career Mitglied ungueltig]: erwartet ok:false "plan facts invalid", got %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = 'career_planning__lena') THEN
    RAISE EXCEPTION 'FAIL [career Mitglied ungueltig]: Plan-Dokument trotz Ablehnung geschrieben'; END IF;
  RAISE NOTICE 'PASS [Karriere-Plan eines Mitglieds: ungueltiger Plan abgelehnt]';

  -- gueltig -> veroeffentlicht
  v_res := agent.fn_advisor_save_section(jsonb_build_object('domain','career','chat_id','111','section_key','s1',
    'section_content','x','section_data', jsonb_build_object('target_roles', jsonb_build_array(
      jsonb_build_object('title','Data Analyst','salary_expectation_eur',75000,'salary_period','year','salary_basis','gross')),
      'target_date','2028')));
  v_res := agent.fn_advisor_publish_plan(jsonb_build_object('domain','career','chat_id','111','plan_md','# Plan'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [career gueltig]: got %', v_res; END IF;
  RAISE NOTICE 'PASS [Karriere-Plan: gueltiger Plan veroeffentlicht]';
END $$;

ROLLBACK;
