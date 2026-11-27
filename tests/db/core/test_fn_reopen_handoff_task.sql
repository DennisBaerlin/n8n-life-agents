-- tests/db/core/test_fn_reopen_handoff_task.sql
-- core.fn_reopen_handoff_task: eine nicht bestaetigte Karte gibt ihre Vormerkung sofort frei (kein Warten auf die Claim-Frist).
--   * working -> open, claimed_at bleibt (Stelle k von n); [Jetzt eintragen] beansprucht sie sofort wieder;
--   * die freigegebene Aufgabe bleibt in derselben Runde eintragbar (core.fn_handoff_task_check, core.fn_complete_handoff_task),
--     eine nie beanspruchte offene und eine freigegebene nach der Frist nicht;
--   * done mit missing (noch nicht eingetragene Teile) -> neue Aufgabe open mit follows_task_id und wanted = missing,
--     hoechstens eine; die alte nimmt danach keinen weiteren Teil an, die neue ist in derselben Runde eintragbar;
--     done ohne missing, deferred, cancelled bleiben unveraendert;
--   * fremde Person, unbekannte oder nicht numerische id -> handoff_task_invalid.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_w int; v_w2 int; v_never int; v_done int; v_done2 int; v_def int; v_can int; v_new int;
  v_claim timestamptz;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name = 'financial_planning';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true);
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version) VALUES ('finance', NULL, 'T', 'active', 1);

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','recurring_transfer','Karte abgebrochen','working', now() - interval '2 minutes') RETURNING id INTO v_w;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance','finance','erika','s','other','noch in der Runde','working', now() - interval '2 minutes') RETURNING id INTO v_w2;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance','finance','erika','s','other','nie beansprucht') RETURNING id INTO v_never;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, why, status, claimed_at, closed_at, close_reason, wanted, entered_refs)
  VALUES ('finance','finance','erika','s','Thema','recurring_transfer','zwei Teile','Grund.','done', now(), now(), 'entered',
          '[{"tool":"create_x","input":{"n":1}},{"tool":"create_x","input":{"n":2}}]', '[{"type":"x","id":1}]') RETURNING id INTO v_done;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at, close_reason)
  VALUES ('finance','finance','erika','s','other','ganz erledigt','done', now(), now(), 'entered') RETURNING id INTO v_done2;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, blocked_code)
  VALUES ('finance','finance','erika','s','other','zurueckgestellt','deferred','end_date_future') RETURNING id INTO v_def;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at, close_reason)
  VALUES ('finance','finance','erika','s','other','gestrichen','cancelled', now(), 'dropped') RETURNING id INTO v_can;
  SELECT claimed_at INTO v_claim FROM agent.handoff_tasks WHERE id = v_w;

  -- ---------- 1) Ablehnungen ----------
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_w, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 fremde Person]: %', r; END IF;
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', '999999', 'chat_id', '111'));
  IF r->>'code' IS DISTINCT FROM 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 unbekannt]: %', r; END IF;
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', 'abc', 'chat_id', '111'));
  IF r->>'code' IS DISTINCT FROM 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 nicht numerisch]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_w) <> 'working' THEN RAISE EXCEPTION 'FAIL [1 Ablehnung schrieb]'; END IF;
  RAISE NOTICE 'PASS [1 Ablehnungen]';

  -- ---------- 2) working -> open, sofort wieder beanspruchbar ----------
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_w::text, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'task_id')::int <> v_w OR r->>'status' <> 'open' OR r ? 'follow_task_id' THEN
    RAISE EXCEPTION 'FAIL [2 Rueckgabe]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_w) <> 'open'
     OR (SELECT claimed_at FROM agent.handoff_tasks WHERE id = v_w) IS DISTINCT FROM v_claim THEN
    RAISE EXCEPTION 'FAIL [2 Zustand]: %', (SELECT to_jsonb(t) FROM agent.handoff_tasks t WHERE id = v_w); END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_w2) <> 'working' THEN RAISE EXCEPTION 'FAIL [2 andere Aufgabe der Runde angefasst]'; END IF;
  IF core.fn_handoff_position(v_w) IS DISTINCT FROM '{"k": 1, "n": 2}'::jsonb THEN RAISE EXCEPTION 'FAIL [2 Stelle]: %', core.fn_handoff_position(v_w); END IF;
  -- wiederholbar
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_w, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'open' THEN RAISE EXCEPTION 'FAIL [2 zweimal]: %', r; END IF;
  RAISE NOTICE 'PASS [2 working -> open]';

  -- ---------- 3) in derselben Runde weiter eintragbar; nie beansprucht oder Frist vorbei: nicht ----------
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_w, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'part')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [3 freigegeben eintragbar]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_never, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [3 nie beansprucht]: %', r; END IF;
  UPDATE agent.handoff_tasks SET claimed_at = now() - interval '5 hours' WHERE id = v_w;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_w, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [3 Frist vorbei]: %', r; END IF;
  UPDATE agent.handoff_tasks SET claimed_at = v_claim WHERE id = v_w;
  r := core.fn_complete_handoff_task(jsonb_build_object('handoff_task_id', v_w, 'chat_id', '111', 'entered_refs', '[{"type":"x","id":9}]'::jsonb));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status || '/' || close_reason FROM agent.handoff_tasks WHERE id = v_w) <> 'done/entered' THEN
    RAISE EXCEPTION 'FAIL [3 Abschluss aus open]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Runde]';

  -- ---------- 4) [Jetzt eintragen] beansprucht eine freigegebene Aufgabe sofort ----------
  PERFORM core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_w2, 'chat_id', '111'));
  r := core.fn_handle_handoff_cb(jsonb_build_object('data', 'handoff:finance:' || v_w2, 'chat_id', '111', 'chat_type', 'private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'task_ids' IS DISTINCT FROM jsonb_build_array(v_w2) THEN RAISE EXCEPTION 'FAIL [4 erneuter Claim]: %', r; END IF;
  RAISE NOTICE 'PASS [4 erneuter Claim]';

  -- ---------- 5) done mit fehlendem Teil -> Folge-Aufgabe open ----------
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_done, 'chat_id', '111',
         'missing', '[{"tool":"create_x","input":{"n":2}}]'::jsonb));
  v_new := (r->>'follow_task_id')::int;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'done' OR v_new IS NULL THEN RAISE EXCEPTION 'FAIL [5 Rueckgabe]: %', r; END IF;
  IF (SELECT status || '|' || follows_task_id || '|' || text || '|' || why || '|' || topic || '|' || (claimed_at IS NULL)
        FROM agent.handoff_tasks WHERE id = v_new) IS DISTINCT FROM 'open|' || v_done || '|zwei Teile|Grund.|Thema|true'
     OR (SELECT wanted FROM agent.handoff_tasks WHERE id = v_new) IS DISTINCT FROM '{"tool":"create_x","input":{"n":2}}'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5 Folge-Aufgabe]: %', (SELECT to_jsonb(t) FROM agent.handoff_tasks t WHERE id = v_new); END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_done) <> 'done' THEN RAISE EXCEPTION 'FAIL [5 alte Aufgabe angefasst]'; END IF;
  -- der Rest laeuft nur noch ueber die neue Aufgabe: die alte nimmt keinen weiteren Teil mehr an (sonst stuende er doppelt da),
  -- die neue ist im selben Gespraech sofort eintragbar
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_done, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' OR position(v_new::text IN r->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL [5 alte Aufgabe nimmt weiteren Teil an]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_new, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'part')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 neue Aufgabe sofort eintragbar]: %', r; END IF;
  -- so (ohne eigenen Claim) eingetragen, nimmt sie in derselben Runde auch ihren weiteren Teil an
  r := core.fn_complete_handoff_task(jsonb_build_object('handoff_task_id', v_new, 'chat_id', '111', 'entered_refs', '[{"type":"x","id":2}]'::jsonb));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5 Folge-Aufgabe abschliessen]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_new, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'part')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [5 weiterer Teil der Folge-Aufgabe]: %', r; END IF;
  -- zweite Karte desselben Teils abgebrochen: keine zweite Folge-Aufgabe
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_done, 'chat_id', '111',
         'missing', '[{"tool":"create_x","input":{"n":2}}]'::jsonb));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'follow_task_id')::int IS DISTINCT FROM v_new
     OR (SELECT count(*) FROM agent.handoff_tasks WHERE follows_task_id = v_done) <> 1 THEN RAISE EXCEPTION 'FAIL [5 zweimal]: %', r; END IF;
  -- mehrere fehlende Teile bleiben eine Liste
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_done2, 'chat_id', '111',
         'missing', '[{"tool":"create_x","input":{"n":2}},{"tool":"create_x","input":{"n":3}}]'::jsonb));
  IF jsonb_typeof((SELECT wanted FROM agent.handoff_tasks WHERE id = (r->>'follow_task_id')::int)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'FAIL [5 Liste]: %', r; END IF;
  RAISE NOTICE 'PASS [5 fehlender Teil]';

  -- ---------- 6) unveraendert: done ohne missing, deferred, cancelled ----------
  DELETE FROM agent.handoff_tasks WHERE follows_task_id = v_done2;
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_done2, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'done' OR r ? 'follow_task_id'
     OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE follows_task_id = v_done2) THEN RAISE EXCEPTION 'FAIL [6 done ohne missing]: %', r; END IF;
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_def, 'chat_id', '111', 'missing', '[{"tool":"x","input":{}}]'::jsonb));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'deferred' OR r ? 'follow_task_id' THEN RAISE EXCEPTION 'FAIL [6 deferred]: %', r; END IF;
  r := core.fn_reopen_handoff_task(jsonb_build_object('handoff_task_id', v_can, 'chat_id', '111', 'missing', '[{"tool":"x","input":{}}]'::jsonb));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'cancelled' OR r ? 'follow_task_id' THEN RAISE EXCEPTION 'FAIL [6 cancelled]: %', r; END IF;
  RAISE NOTICE 'PASS [6 unveraendert]';
END $$;

ROLLBACK;
