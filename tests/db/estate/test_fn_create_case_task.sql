-- tests/db/estate/test_fn_create_case_task.sql
-- WS-3: manuelle Task hinzufuegen — adults_only, nur offene Faelle, mehrere manuelle Tasks (kein NULL-Trap).
BEGIN;

DO $$
DECLARE v_r JSONB; v_case BIGINT; v_n INT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern'));
  v_case := (v_r->>'case_id')::bigint;

  -- Kind-Reject.
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','333','case_id', v_case, 'title','Oma anrufen'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN RAISE EXCEPTION 'FAIL [create_case_task Kind-Reject]: %', v_r; END IF;

  -- leerer Titel.
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title',''));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%title is required%' THEN RAISE EXCEPTION 'FAIL [leerer Titel]: %', v_r; END IF;

  -- Happy + zweite manuelle Task (kein UNIQUE-Trap trotz template_key NULL + subject_ref '').
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','Blumen fuer die Beerdigung','phase','first_week','due_date','2024-01-25'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [manuelle Task 1]: %', v_r; END IF;
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','Traueranzeige aufgeben'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [manuelle Task 2]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.case_tasks WHERE case_id=v_case AND template_key IS NULL;
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [manuelle Tasks: % statt 2 (NULL-Trap?)]', v_n; END IF;
  RAISE NOTICE 'PASS [create_case_task: Kind/leer/2x manuell kein NULL-Trap]';

  -- ungueltige phase.
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','X','phase','irgendwann'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%phase must be%' THEN RAISE EXCEPTION 'FAIL [invalid phase]: %', v_r; END IF;

  -- WP3: relative Faelligkeit rechnet die DB; Freitext -> ok:false
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','Auto abholen','due_date','in 3 days'));
  IF (v_r->>'due_date')::date IS DISTINCT FROM core.fn_today() + 3
     OR (SELECT due_date FROM estate.case_tasks WHERE id = (v_r->>'case_task_id')::bigint) IS DISTINCT FROM core.fn_today() + 3 THEN
    RAISE EXCEPTION 'FAIL [relative due_date]: %', v_r; END IF;
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','X2','due_date','naechste Woche'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Freitext due_date akzeptiert]: %', v_r; END IF;

  -- nicht offener Fall.
  PERFORM estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', v_case));
  v_r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case, 'title','Zu spaet'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not open%' THEN RAISE EXCEPTION 'FAIL [nicht offener Fall]: %', v_r; END IF;
  RAISE NOTICE 'PASS [create_case_task: phase-Guard + nur offene Faelle]';
END $$;

ROLLBACK;
