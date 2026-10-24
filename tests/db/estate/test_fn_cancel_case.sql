-- tests/db/estate/test_fn_cancel_case.sql
-- WS-3: Fall abbrechen (Break-Glass cancel) — adults_only, nur offen, danach partial-UNIQUE frei.
BEGIN;

DO $$
DECLARE v_r JSONB; v_case BIGINT;
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
  v_r := estate.fn_cancel_case(jsonb_build_object('chat_id','333','case_id', v_case));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN RAISE EXCEPTION 'FAIL [cancel Kind-Reject]: %', v_r; END IF;

  -- nicht gefunden -> {ok:false}, kein RAISE.
  v_r := estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', 999999));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not found%' THEN RAISE EXCEPTION 'FAIL [cancel not found]: %', v_r; END IF;

  -- Happy: offen -> cancelled + closed_at.
  v_r := estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', v_case));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'status' <> 'cancelled' THEN RAISE EXCEPTION 'FAIL [cancel happy]: %', v_r; END IF;
  IF (SELECT status FROM estate.cases WHERE id=v_case) <> 'cancelled'
     OR (SELECT closed_at FROM estate.cases WHERE id=v_case) IS NULL THEN RAISE EXCEPTION 'FAIL [cancel status/closed_at]'; END IF;

  -- erneut cancel -> nicht offen.
  v_r := estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', v_case));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not open%' THEN RAISE EXCEPTION 'FAIL [cancel erneut]: %', v_r; END IF;

  -- Nach cancel ist die partial-UNIQUE frei -> neuer Fall anlegbar (Korrektur = cancel + create).
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-16','bundesland','bayern'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [neuer Fall nach cancel]: %', v_r; END IF;
  RAISE NOTICE 'PASS [cancel_case: Kind/not-found/happy/erneut/re-create]';
END $$;

ROLLBACK;
