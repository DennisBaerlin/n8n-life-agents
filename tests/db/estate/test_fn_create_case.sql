-- tests/db/estate/test_fn_create_case.sql
-- WS-3: Fall-Anlage — adults_only, subject_is_sender, bundesland fail-closed, Datums-Guards, Dublette,
--   incapacity-ueber-death-Reject, Auto-Supersede incapacity->death, Task-Instanziierung (kein NULL-Ref).
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_case BIGINT;
  v_open INT; v_na INT; v_nullref INT;
  v_inc BIGINT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222),
      jsonb_build_object('person_id','oma','first_name','Oma','last_name','M','role','partner','birth_date','1949-02-02'),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- Kind-Reject (chat 333).
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','333','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN RAISE EXCEPTION 'FAIL [Kind-Reject]: %', v_r; END IF;

  -- subject == Sender selbst (erika, chat 111).
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','erika','event_date','2024-01-15','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR NOT COALESCE((v_r->>'subject_is_sender')::boolean,false) THEN RAISE EXCEPTION 'FAIL [subject_is_sender]: %', v_r; END IF;

  -- bundesland fail-closed (kein Parameter, keine Config). code = stabiler Token, reason = freundlicher Satz.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15'));
  IF (v_r->>'ok')::boolean OR v_r->>'code' <> 'bundesland_required' OR v_r->>'reason' NOT LIKE '%Bundesland%' THEN RAISE EXCEPTION 'FAIL [bundesland fail-closed]: %', v_r; END IF;

  -- ungueltiger Bundesland-Slug.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','atlantis'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid bundesland%' THEN RAISE EXCEPTION 'FAIL [invalid bundesland]: %', v_r; END IF;

  -- event_date in der Zukunft.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date', to_char(CURRENT_DATE + 5,'YYYY-MM-DD'),'bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%future%' THEN RAISE EXCEPTION 'FAIL [future event]: %', v_r; END IF;

  -- knowledge < event.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','knowledge_date','2024-01-10','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%before event_date%' THEN RAISE EXCEPTION 'FAIL [knowledge<event]: %', v_r; END IF;

  -- unbekannter subject.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','geist','event_date','2024-01-15','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not a known household member%' THEN RAISE EXCEPTION 'FAIL [unknown subject]: %', v_r; END IF;
  RAISE NOTICE 'PASS [create_case Guards]';

  -- Happy Path: death fuer hans, bayern.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern','flags', jsonb_build_object('tenant', true)));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [happy path]: %', v_r; END IF;
  v_case := (v_r->>'case_id')::bigint;
  IF (v_r->>'total_open')::int < 5 THEN RAISE EXCEPTION 'FAIL [zu wenige offene Tasks: %]', v_r; END IF;
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'open' THEN RAISE EXCEPTION 'FAIL [Fall nicht open]'; END IF;
  SELECT count(*) FILTER (WHERE status='open'), count(*) FILTER (WHERE status='not_applicable')
    INTO v_open, v_na FROM estate.case_tasks WHERE case_id=v_case;
  IF v_open = 0 THEN RAISE EXCEPTION 'FAIL [keine offenen Tasks instanziiert]'; END IF;
  IF v_na = 0 THEN RAISE EXCEPTION 'FAIL [keine sichtbaren n.a.-Tasks (Condition-false erwartet)]'; END IF;
  -- KEIN NULL-subject_ref (NULL-UNIQUE-Falle vermieden).
  SELECT count(*) INTO v_nullref FROM estate.case_tasks WHERE case_id=v_case AND subject_ref IS NULL;
  IF v_nullref <> 0 THEN RAISE EXCEPTION 'FAIL [NULL subject_ref: %]', v_nullref; END IF;
  -- tenant-Flag -> tenancy open (Condition ueber flags).
  IF (SELECT status FROM estate.case_tasks WHERE case_id=v_case AND template_key='tenancy') <> 'open' THEN
    RAISE EXCEPTION 'FAIL [tenant-Flag -> tenancy nicht open]'; END IF;
  RAISE NOTICE 'PASS [create_case Happy Path + Instanziierung]';

  -- Dublette: 2. death fuer hans -> reject.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%already exists%' THEN RAISE EXCEPTION 'FAIL [Dublette]: %', v_r; END IF;
  -- incapacity ueber offenem death -> reject.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','incapacity','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%death case is already open%' THEN RAISE EXCEPTION 'FAIL [incap ueber death]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Dublette + incapacity-ueber-death]';

  -- Auto-Supersede: offener incapacity-Fall (oma) -> death legt an + supersedet incapacity.
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','incapacity','subject_person_id','oma','event_date','2024-01-10','bundesland','bayern'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [incapacity oma]: %', v_r; END IF;
  v_inc := (v_r->>'case_id')::bigint;
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','oma','event_date','2024-01-15','bundesland','bayern'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [death oma nach supersede]: %', v_r; END IF;
  IF (v_r->>'superseded_case_id')::bigint <> v_inc THEN RAISE EXCEPTION 'FAIL [superseded_case_id falsch]: %', v_r; END IF;
  IF (SELECT status FROM estate.cases WHERE id=v_inc) <> 'superseded'
     OR (SELECT closed_at FROM estate.cases WHERE id=v_inc) IS NULL THEN
    RAISE EXCEPTION 'FAIL [incapacity-Fall nicht superseded+closed]'; END IF;
  RAISE NOTICE 'PASS [Auto-Supersede incapacity->death]';
END $$;

ROLLBACK;
