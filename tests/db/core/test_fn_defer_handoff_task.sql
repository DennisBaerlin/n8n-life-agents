-- tests/db/core/test_fn_defer_handoff_task.sql
-- core.fn_defer_handoff_task: open|working -> deferred mit einem Code aus der Liste des Pakets (Katalog-Key
--   <package>.handoff.blocked.<code>); unbekannter Code, fremde Person, Endzustand -> korrigierbar ohne Write.
--   Danach: core.fn_cancel_handoff_task streicht ein deferred (dropped), done_elsewhere aus deferred abgelehnt;
--   core.fn_handoff_overview zaehlt deferred nicht als offen; das Lesefenster liefert why, wanted und den Rest-Text.
BEGIN;

DO $$
DECLARE
  r     jsonb;
  v_id  int; v_id2 int; v_id3 int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.ui_texts (key, lang, text, package)
  VALUES ('finance.handoff.blocked.end_date_future', 'de', 'Ende in der Zukunft geht noch nicht.', 'finance'),
         ('finance.handoff.blocked.tool_missing', 'de', 'Dafür gibt es noch kein Werkzeug.', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.handoff_tasks;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, why, wanted)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'recurring_transfer', 'Dauerauftrag bis Jahresende', 'working', now(),
          'Der Übertrag endet mit dem Ziel.', '{"tool":"create_recurring_transfer","input":{"amount":50}}')
  RETURNING id INTO v_id;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'other', 'Freistellungsauftrag stellen') RETURNING id INTO v_id2;

  -- ---------- 1) Ablehnungen ohne Write ----------
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_id, 'chat_id', '111', 'blocked_code', 'later_maybe'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'unknown_blocked_code'
     OR NOT (r->'valid_codes' @> '["end_date_future","tool_missing"]'::jsonb) THEN RAISE EXCEPTION 'FAIL [1 unbekannter Code]: %', r; END IF;
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_id, 'chat_id', '222', 'blocked_code', 'end_date_future'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 fremde Person]: %', r; END IF;
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', 'x', 'chat_id', '111', 'blocked_code', 'end_date_future'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 keine Zahl]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_id) <> 'working' THEN RAISE EXCEPTION 'FAIL [1 trotzdem geschrieben]'; END IF;
  RAISE NOTICE 'PASS [1 Ablehnungen]';

  -- ---------- 2) working -> deferred, open -> deferred ----------
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_id, 'chat_id', '111', 'blocked_code', 'end_date_future'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'deferred' OR r->>'blocked_code' <> 'end_date_future'
     OR (r->>'task_id')::int <> v_id OR r->>'text' <> 'Dauerauftrag bis Jahresende' THEN RAISE EXCEPTION 'FAIL [2 working]: %', r; END IF;
  IF (SELECT status || '/' || blocked_code FROM agent.handoff_tasks WHERE id = v_id) <> 'deferred/end_date_future' THEN
    RAISE EXCEPTION 'FAIL [2 Zeile]'; END IF;
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'blocked_code', 'tool_missing'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [2 open]: %', r; END IF;
  r := core.fn_defer_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'blocked_code', 'tool_missing'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_closed' THEN RAISE EXCEPTION 'FAIL [2 zweimal]: %', r; END IF;
  RAISE NOTICE 'PASS [2 deferred]';

  -- ---------- 3) deferred zaehlt nicht als offen ----------
  r := core.fn_handoff_overview('{"domain":"finance","chat_id":"111"}');
  IF (r->>'count')::int <> 0 THEN RAISE EXCEPTION 'FAIL [3 Uebersicht zaehlt deferred]: %', r; END IF;
  RAISE NOTICE 'PASS [3 nicht offen]';

  -- ---------- 4) streichen aus deferred, schon-im-System aus deferred abgelehnt ----------
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'reason', 'done_elsewhere'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_deferred' THEN RAISE EXCEPTION 'FAIL [4 done_elsewhere]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_deferred' THEN RAISE EXCEPTION 'FAIL [4 skipped]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'reason', 'dropped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status || '/' || close_reason FROM agent.handoff_tasks WHERE id = v_id2) <> 'cancelled/dropped' THEN
    RAISE EXCEPTION 'FAIL [4 dropped]: %', r; END IF;
  RAISE NOTICE 'PASS [4 cancel aus deferred]';

  -- ---------- 5) Lesefenster: why, wanted, rest ----------
  -- Ids beginnen je Entwurf neu: der gueltige Plan fuehrt Id 4 fuer einen anderen Punkt; zaehlt die Plan-Zeile der Vereinbarung
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, created_at)
  VALUES ('finance', NULL, 'T', 'active', 1, jsonb_build_object('goals_triggers', jsonb_build_object('topics', jsonb_build_array(
    jsonb_build_object('topic', 'Kita', 'content', 'c', 'open_points', jsonb_build_array(jsonb_build_object('id', 4, 'text', 'anderer Punkt des gueltigen Plans')))))),
    now() - interval '10 days');
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'T', 'draft', 2, jsonb_build_object('goals_triggers', jsonb_build_object('topics', jsonb_build_array(
    jsonb_build_object('topic', 'Rente', 'content', 'c', 'open_points', jsonb_build_array(jsonb_build_object('id', 4, 'text', 'Betrag, sobald der Anbieter sich meldet')))))));
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, open_point_id)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'Rente', 'other', 'Betriebsrente eintragen', 4) RETURNING id INTO v_id3;
  r := core.fn_handoff_tasks_read(ARRAY[v_id, v_id3]);
  IF r->0->>'why' <> 'Der Übertrag endet mit dem Ziel.' OR r->0->'wanted'->>'tool' <> 'create_recurring_transfer'
     OR r->0->'rest' <> 'null'::jsonb OR r->1->>'rest' <> 'Betrag, sobald der Anbieter sich meldet' THEN
    RAISE EXCEPTION 'FAIL [5 read]: %', r; END IF;
  -- Provenienz fuer die Paket-fns (Unterschied, Kartenzeilen): entered_refs, close_reason, open_point_id
  UPDATE agent.handoff_tasks SET status = 'done', closed_at = now(), close_reason = 'done_elsewhere',
         entered_refs = '[{"type":"pension","id":2}]' WHERE id = v_id3;
  r := core.fn_handoff_tasks_read(ARRAY[v_id3]);
  IF r->0->'entered_refs' IS DISTINCT FROM '[{"type":"pension","id":2}]'::jsonb OR r->0->>'close_reason' IS DISTINCT FROM 'done_elsewhere'
     OR (r->0->>'open_point_id')::int IS DISTINCT FROM 4 OR r->0 ? 'person_id' THEN RAISE EXCEPTION 'FAIL [5 Provenienz]: %', r; END IF;
  RAISE NOTICE 'PASS [5 Lesefenster]';
END $$;

ROLLBACK;
