-- tests/db/estate/test_estate_cases_schema.sql
-- WS-3 DDL-Invarianten: cases/case_tasks/task_templates CHECKs + partial-UNIQUE + Auto-Complete-Trigger.
BEGIN;

DO $$
DECLARE
  v_ok BOOLEAN;
  v_case BIGINT;
BEGIN
  -- Fixture-Person (subject FK).
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(jsonb_build_object('person_id','hans','first_name','Hans','last_name','H',
      'role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- knowledge_date >= event_date CHECK.
  v_ok := false;
  BEGIN
    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland)
    VALUES ('death','hans','2024-05-10','2024-05-01','bayern');
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [knowledge<event nicht geblockt]'; END IF;

  -- bundesland CHECK (unbekannter Slug).
  v_ok := false;
  BEGIN
    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland)
    VALUES ('death','hans','2024-05-10','2024-05-10','atlantis');
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [unbekannter Bundesland-Slug nicht geblockt]'; END IF;

  -- closed_at-Konsistenz: open MUSS closed_at NULL haben.
  v_ok := false;
  BEGIN
    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland, status, closed_at)
    VALUES ('death','hans','2024-05-10','2024-05-10','bayern','open', now());
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [open mit closed_at nicht geblockt]'; END IF;

  -- Happy insert -> dann partial-UNIQUE(subject) WHERE open: ein 2. offener Fall blockt.
  INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland)
  VALUES ('death','hans','2024-05-10','2024-05-10','bayern') RETURNING id INTO v_case;
  v_ok := false;
  BEGIN
    INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland)
    VALUES ('incapacity','hans','2024-05-10','2024-05-10','bayern');
  EXCEPTION WHEN unique_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [2. offener Fall je Person nicht geblockt]'; END IF;
  -- Aber ein nicht-offener (cancelled) 2. Fall ist erlaubt.
  INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland, status, closed_at)
  VALUES ('incapacity','hans','2024-04-01','2024-04-01','bayern','cancelled', now());
  RAISE NOTICE 'PASS [cases-CHECKs + partial-UNIQUE ein offener Fall/Person]';

  -- task_templates offset-Paarung: count gesetzt aber unit NULL -> CHECK.
  v_ok := false;
  BEGIN
    INSERT INTO estate.task_templates (template_key, case_type, phase, ord, title, offset_count, offset_unit)
    VALUES ('zz_test','death','later',999,'X', 3, NULL);
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [offset_count ohne unit nicht geblockt]'; END IF;
  RAISE NOTICE 'PASS [task_templates offset-Paarung-CHECK]';

  -- Auto-Complete-Trigger: alle offenen Tasks done -> Fall completed + closed_at.
  INSERT INTO estate.case_tasks (case_id, template_key, subject_ref, phase, title, status)
  VALUES (v_case, NULL, '', 'immediate', 'T1', 'open'), (v_case, NULL, '', 'immediate', 'T2', 'open');
  UPDATE estate.case_tasks SET status='done', done_at=now() WHERE case_id=v_case AND title='T1';
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'open' THEN
    RAISE EXCEPTION 'FAIL [Fall vorzeitig completed (noch offene Task)]'; END IF;
  UPDATE estate.case_tasks SET status='not_applicable' WHERE case_id=v_case AND title='T2';
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'completed'
     OR (SELECT closed_at FROM estate.cases WHERE id=v_case) IS NULL THEN
    RAISE EXCEPTION 'FAIL [letzte Task done/n.a. -> Fall nicht completed+closed_at]'; END IF;
  -- Reopen-Zweig (defensiv): eine Task wieder open -> Fall zurueck auf open.
  UPDATE estate.case_tasks SET status='open', done_at=NULL WHERE case_id=v_case AND title='T1';
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'open'
     OR (SELECT closed_at FROM estate.cases WHERE id=v_case) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [Task wieder open -> Fall nicht reopened]'; END IF;
  RAISE NOTICE 'PASS [Auto-Complete-Trigger: complete + reopen]';

  -- WP3: done_at gehoert genau zu status='done' (CHECK case_tasks_done_at_consistency)
  v_ok := false;
  BEGIN
    UPDATE estate.case_tasks SET status='done' WHERE case_id=v_case AND title='T2';
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [done ohne done_at nicht geblockt]'; END IF;
  v_ok := false;
  BEGIN
    UPDATE estate.case_tasks SET done_at=now() WHERE case_id=v_case AND title='T1';
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [done_at an offener Task nicht geblockt]'; END IF;
  v_ok := false;
  BEGIN
    UPDATE estate.case_tasks SET status_source='llm' WHERE case_id=v_case AND title='T1';
  EXCEPTION WHEN check_violation THEN v_ok := true; END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [status_source ausserhalb system|user nicht geblockt]'; END IF;
  RAISE NOTICE 'PASS [CHECK done_at <-> done, status_source-Wertevorrat]';
END $$;

ROLLBACK;
