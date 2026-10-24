-- tests/db/estate/test_fn_handle_case_task_callback.sql
-- WS-3 + Member-Permeabilitaet: est:-Callback-Handler — done/skip delegiert an fn_set_case_task; unresolved
--   sender, unbekannte Aktion, stale id, Kind (adults_only via Delegat), **Partner-Actor** (member-permeabel:
--   ein Nicht-Owner-Erwachsener handelt an einem subject-fremden Fall = Break-Glass). NIE RAISE (Dispatcher-Vertrag).
BEGIN;

DO $$
DECLARE v_r JSONB; v_case BIGINT; v_task BIGINT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222,'language','ko'),
      jsonb_build_object('person_id','kid','first_name','Kim','last_name','M','role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- Katalog-Fixture: Text = Sprach-Marker + Key (Toast in der Sprache des Tippenden; Kind ohne Sprache -> Owner de).
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, split_part(k, '.', 1)
  FROM unnest(ARRAY['core.toast.unresolved_sender','core.toast.unknown_action','core.toast.save_failed',
                    'estate.toast.invalid_task','estate.toast.task_done','estate.toast.task_not_applicable',
                    'estate.toast.adults_only','estate.toast.case_closed','estate.toast.task_not_found']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  v_r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans','event_date','2024-01-15','bundesland','bayern'));
  v_case := (v_r->>'case_id')::bigint;
  SELECT id INTO v_task FROM estate.case_tasks WHERE case_id=v_case AND template_key='order_death_certs';

  -- unresolved sender (chat 999 nicht in family).
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:done:'||v_task, 'chat_id','999'));
  IF (v_r->>'ok')::boolean OR v_r->>'toast' <> 'DE:core.toast.unresolved_sender' THEN RAISE EXCEPTION 'FAIL [unresolved sender]: %', v_r; END IF;

  -- unbekannte Aktion.
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:foo:'||v_task, 'chat_id','111'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%unknown est action%' OR v_r->>'toast' <> 'DE:core.toast.unknown_action' THEN RAISE EXCEPTION 'FAIL [unknown action]: %', v_r; END IF;

  -- Kind (in family, aber role=child) -> Delegat lehnt via adults_only ab -> toast.
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:done:'||v_task, 'chat_id','333'));
  IF (v_r->>'ok')::boolean OR v_r->>'toast' <> 'DE:estate.toast.adults_only' THEN RAISE EXCEPTION 'FAIL [Kind via callback]: %', v_r; END IF;

  -- stale id.
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:done:999999', 'chat_id','111'));
  IF (v_r->>'ok')::boolean OR v_r->>'toast' <> 'DE:estate.toast.task_not_found' THEN RAISE EXCEPTION 'FAIL [stale id]: %', v_r; END IF;

  -- Happy done (Owner 111) -> Task done.
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:done:'||v_task, 'chat_id','111'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'toast' <> 'DE:estate.toast.task_done' THEN RAISE EXCEPTION 'FAIL [done happy]: %', v_r; END IF;
  IF (SELECT status FROM estate.case_tasks WHERE id=v_task) <> 'done' THEN RAISE EXCEPTION 'FAIL [Task nicht done]'; END IF;

  -- Happy skip auf einer anderen Task -> not_applicable.
  SELECT id INTO v_task FROM estate.case_tasks WHERE case_id=v_case AND template_key='engage_undertaker';
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:skip:'||v_task, 'chat_id','111'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'toast' <> 'DE:estate.toast.task_not_applicable' THEN RAISE EXCEPTION 'FAIL [skip happy]: %', v_r; END IF;
  IF (SELECT status FROM estate.case_tasks WHERE id=v_task) <> 'not_applicable' THEN RAISE EXCEPTION 'FAIL [Task nicht n.a.]'; END IF;

  -- PARTNER-Actor (D4 Haushalts-Policy, Member-Callback-Permeabilitaet): der EXAKTE Break-Glass-Fall — die
  -- Ownerin erika wird handlungsunfaehig, der Partner hans (222 = Nicht-Owner-Erwachsener) OEFFNET den Fall
  -- (subject=erika, sender=hans, subject<>sender ok) UND handelt an dessen Tasks -> ok. Beweist: adults_only
  -- ist HAUSHALTS-skopiert, KEIN Per-Item-Eigentum -> der handelnde Partner arbeitet an der Mappe der/des
  -- Betroffenen (ein Per-Item-Check wuerde genau ihn aussperren).
  v_r := estate.fn_create_case(jsonb_build_object('chat_id','222','case_type','incapacity','subject_person_id','erika','event_date','2024-02-01','bundesland','bayern'));
  v_case := (v_r->>'case_id')::bigint;
  IF v_case IS NULL THEN RAISE EXCEPTION 'FAIL [Partner-Actor Setup]: fn_create_case gab keinen case_id: %', v_r; END IF;
  SELECT id INTO v_task FROM estate.case_tasks WHERE case_id=v_case ORDER BY id LIMIT 1;
  v_r := estate.fn_handle_case_task_callback(jsonb_build_object('data','est:done:'||v_task, 'chat_id','222'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'toast' <> 'KO:estate.toast.task_done' THEN RAISE EXCEPTION 'FAIL [Partner-Actor an subject-fremdem Fall]: %', v_r; END IF;
  IF (SELECT status FROM estate.case_tasks WHERE id=v_task) <> 'done' THEN RAISE EXCEPTION 'FAIL [Partner-done Task nicht done]'; END IF;

  RAISE NOTICE 'PASS [est:-Callback: unresolved/unknown/Kind/stale/done/skip/Partner-Actor]';
END $$;

ROLLBACK;
