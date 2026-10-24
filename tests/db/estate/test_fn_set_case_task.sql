-- tests/db/estate/test_fn_set_case_task.sql
-- WS-3: Task-Status setzen (Fortschritts-Flag, kein HITL) — adults_only, nur Tasks offener Faelle,
--   done_at, Auto-Complete des Falls, invalider Status.
BEGIN;

DO $$
DECLARE v_r JSONB; v_case BIGINT; v_task BIGINT; v_id BIGINT; v_completed BOOLEAN := false;
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
  SELECT id INTO v_task FROM estate.case_tasks WHERE case_id=v_case AND template_key='death_certificate';

  -- Kind-Reject.
  v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','333','case_task_id', v_task, 'status','done'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN RAISE EXCEPTION 'FAIL [set_case_task Kind-Reject]: %', v_r; END IF;

  -- invalider Status.
  v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_task, 'status','maybe'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%status must be%' THEN RAISE EXCEPTION 'FAIL [invalid status]: %', v_r; END IF;

  -- Happy: done -> done_at gesetzt.
  v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_task, 'status','done'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'status' <> 'done' THEN RAISE EXCEPTION 'FAIL [set done]: %', v_r; END IF;
  IF (SELECT done_at FROM estate.case_tasks WHERE id=v_task) IS NULL THEN RAISE EXCEPTION 'FAIL [done_at nicht gesetzt]'; END IF;
  -- zurueck auf open -> done_at NULL.
  v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_task, 'status','open'));
  IF (SELECT done_at FROM estate.case_tasks WHERE id=v_task) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [done_at nicht geleert]'; END IF;
  RAISE NOTICE 'PASS [set_case_task: Kind/invalid/done/open + done_at]';

  -- Auto-Complete: ALLE offenen Tasks abarbeiten -> Fall completed (der letzte Call meldet case_completed).
  FOR v_id IN SELECT id FROM estate.case_tasks WHERE case_id=v_case AND status='open' ORDER BY id LOOP
    v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_id, 'status','done'));
    IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [Abarbeiten Task %]: %', v_id, v_r; END IF;
    v_completed := COALESCE((v_r->>'case_completed')::boolean, false);
  END LOOP;
  IF NOT v_completed THEN RAISE EXCEPTION 'FAIL [letzter Call meldet case_completed nicht]'; END IF;
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'completed' THEN RAISE EXCEPTION 'FAIL [Fall nicht completed]'; END IF;
  RAISE NOTICE 'PASS [Auto-Complete ueber fn_set_case_task]';

  -- Task eines nicht-offenen Falls -> reject.
  v_r := estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_task, 'status','open'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not open%' THEN RAISE EXCEPTION 'FAIL [Task nicht-offener Fall]: %', v_r; END IF;
  RAISE NOTICE 'PASS [set_case_task nur Tasks offener Faelle]';
END $$;

ROLLBACK;
