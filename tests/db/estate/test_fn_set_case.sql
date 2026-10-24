-- tests/db/estate/test_fn_set_case.sql
-- WS-3: Fall aendern (knowledge/bundesland/flags) -> Fristen-Recompute + ADDITIVER Reconcile;
--   nichts auto-n.a. (done/open bleiben). adults_only, nur offen.
BEGIN;

DO $$
DECLARE v_r JSONB; v_case BIGINT; v_due0 DATE; v_due1 DATE; v_task BIGINT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','knowledge_date','2024-01-15','bundesland','bayern'));
  v_case := (v_r->>'case_id')::bigint;

  -- tenant nicht gesetzt -> tenancy n.a.
  IF (SELECT status FROM estate.case_tasks WHERE case_id=v_case AND template_key='tenancy') <> 'not_applicable' THEN
    RAISE EXCEPTION 'FAIL [tenancy vor set nicht n.a.]'; END IF;
  -- knowledge-anker-Frist vor der Aenderung (inheritance_refusal = knowledge + 42).
  SELECT due_date INTO v_due0 FROM estate.case_tasks WHERE case_id=v_case AND template_key='inheritance_refusal';
  -- eine Task done markieren (darf beim Reconcile NICHT zurueckgesetzt werden).
  SELECT id INTO v_task FROM estate.case_tasks WHERE case_id=v_case AND template_key='death_certificate';
  PERFORM estate.fn_set_case_task(jsonb_build_object('chat_id','111','case_task_id', v_task, 'status','done'));

  -- Kind-Reject.
  v_r := estate.fn_set_case(jsonb_build_object('chat_id','333','case_id', v_case, 'flags', jsonb_build_object('tenant',true)));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN RAISE EXCEPTION 'FAIL [set_case Kind-Reject]: %', v_r; END IF;

  -- set_case: flags{tenant:true} + neues knowledge_date -> Reconcile + Recompute.
  v_r := estate.fn_set_case(jsonb_build_object('chat_id','111','case_id', v_case, 'flags', jsonb_build_object('tenant',true), 'knowledge_date','2024-01-20'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set_case happy]: %', v_r; END IF;

  -- additiver Reconcile: tenancy n.a. -> open.
  IF (SELECT status FROM estate.case_tasks WHERE case_id=v_case AND template_key='tenancy') <> 'open' THEN
    RAISE EXCEPTION 'FAIL [Reconcile: tenancy nicht auf open gekippt]'; END IF;
  -- Recompute: inheritance_refusal-Frist verschoben (knowledge 15.->20. -> +5 Tage).
  SELECT due_date INTO v_due1 FROM estate.case_tasks WHERE case_id=v_case AND template_key='inheritance_refusal';
  IF v_due1 <> v_due0 + 5 THEN RAISE EXCEPTION 'FAIL [Recompute knowledge-Anker: % statt %]', v_due1, v_due0 + 5; END IF;
  -- nichts auto-n.a.: die done-Task bleibt done.
  IF (SELECT status FROM estate.case_tasks WHERE id=v_task) <> 'done' THEN
    RAISE EXCEPTION 'FAIL [done-Task durch Reconcile zurueckgesetzt]'; END IF;
  RAISE NOTICE 'PASS [set_case: Reconcile n.a.->open + Recompute + done bleibt done]';

  -- nicht offen -> reject.
  PERFORM estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', v_case));
  v_r := estate.fn_set_case(jsonb_build_object('chat_id','111','case_id', v_case, 'flags', jsonb_build_object('employed',true)));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not open%' THEN RAISE EXCEPTION 'FAIL [set_case nicht offen]: %', v_r; END IF;
  RAISE NOTICE 'PASS [set_case nur offen]';
END $$;

ROLLBACK;
