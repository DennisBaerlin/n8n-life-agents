-- tests/db/core/test_fn_handoff_tasks.sql
-- Uebergabe Berater -> Buchhalter (agent.handoff_tasks, 2026-11-07):
--   * agent.fn_advisor_save_section legt handoff_tasks mit dem Abschnitt an (Karte: card_lines), Neu-Speichern ersetzt nur
--     die offenen Aufgaben dieses Abschnitts; korrigierbare Eingaben -> {ok:false} ohne Write;
--   * core.fn_handoff_overview: offene Aufgaben der Person + max_task_id;
--   * core.fn_handle_handoff_cb: Privatchat, Tippender = Person, can_write, Claim open -> working (Doppeltipp, veraltetes
--     max, Re-Claim nach TTL); core.fn_release_handoff_tasks gibt Claims frei;
--   * core.fn_handoff_tasks_read / fn_handoff_task_check / fn_complete_handoff_task / fn_cancel_handoff_task;
--   * Endzustand unveraenderlich (Trigger), CHECKs;
--   * Themen: ein Themen-Save ersetzt die offenen Aufgaben seines Themas plus die themenlosen des Abschnitts.
BEGIN;

DO $$
DECLARE
  r     jsonb;
  v_id1 int; v_id2 int; v_id3 int; v_idw int;
  v_n   int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name = 'financial_planning';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, 'finance.fn_plan_gap_count', 'finance.fn_plan_readiness');
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('handoff', 'core.fn_handle_handoff_cb', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT k, l, upper(l) || ':' || k, 'core'
  FROM unnest(ARRAY['core.toast.plan_private_only','core.toast.area_unavailable','core.toast.plan_owner_only',
                    'core.toast.handoff_nothing_open']) k
  CROSS JOIN (VALUES ('de'), ('en'), ('ko')) ls(l)
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';

  -- ---------- 1) Abschnitt mit zwei Aufgaben speichern ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','goals_triggers','topic','Allgemein',
         'section_content','Emergency fund and a car.',
         'handoff_tasks', jsonb_build_array(
            jsonb_build_object('kind','savings_goal','payload',jsonb_build_object('name','Notgroschen','target_amount',6000),'text','Sparziel Notgroschen 6.000 €'),
            jsonb_build_object('kind','savings_plan','text','Sparplan 200 € auf den ETF'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_count')::int <> 2 THEN RAISE EXCEPTION 'FAIL [1 save]: %', r; END IF;
  IF jsonb_array_length(r->'card_lines') <> 2 OR r->'card_lines'->0->>'value' <> 'core.hitl.handoff_planned'
     OR r->'card_lines'->0->'params'->>'text' <> 'Sparziel Notgroschen 6.000 €' THEN RAISE EXCEPTION 'FAIL [1 card_lines]: %', r; END IF;
  SELECT count(*) INTO v_n FROM agent.handoff_tasks
   WHERE domain = 'finance' AND package = 'finance' AND person_id = 'erika' AND section_key = 'goals_triggers' AND status = 'open';
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [1 Zeilen]: % offene', v_n; END IF;
  IF (SELECT payload FROM agent.handoff_tasks WHERE kind = 'savings_plan') <> '{}'::jsonb THEN RAISE EXCEPTION 'FAIL [1 payload default]'; END IF;
  RAISE NOTICE 'PASS [1 save mit handoff_tasks]';

  -- ---------- 2) korrigierbare Eingaben -> ok:false, kein Write ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','loan','text','Kredit'))));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 kind]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text',repeat('a',301)))));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 text lang]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','  '))));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 text leer]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','t','payload','[1]'::jsonb))));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 payload]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', 'not json'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 kein JSON]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', '{"kind":"other"}'::jsonb));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [2 kein Array]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE domain = 'finance' AND interview_state ? 'risk_profile') THEN
    RAISE EXCEPTION 'FAIL [2 Abschnitt trotz Ablehnung gespeichert]'; END IF;
  -- JSON-String-Form (Tool-Binding liefert Strings), leerer String = nicht angegeben
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', '[{"kind":"other","text":"Haftpflicht prüfen"}]'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_count')::int <> 1 THEN RAISE EXCEPTION 'FAIL [2 String-Form]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','household_basics','topic','Allgemein',
         'section_content','x','handoff_tasks', ''));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'handoff_task_count')::int <> 0 OR jsonb_array_length(r->'card_lines') <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 leerer String]: %', r; END IF;
  RAISE NOTICE 'PASS [2 korrigierbare Eingaben]';

  -- ---------- 3) Neu-Speichern ersetzt nur offene Aufgaben dieses Abschnitts ----------
  UPDATE agent.handoff_tasks SET status = 'working', claimed_at = now() WHERE kind = 'savings_plan' RETURNING id INTO v_idw;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','goals_triggers','topic','Allgemein',
         'section_content','Emergency fund only.',
         'handoff_tasks', jsonb_build_array(jsonb_build_object('kind','savings_goal','text','Sparziel Notgroschen 5.000 €'))));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3 save]: %', r; END IF;
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE section_key = 'goals_triggers' AND status = 'open') <> 1
     OR (SELECT text FROM agent.handoff_tasks WHERE section_key = 'goals_triggers' AND status = 'open') <> 'Sparziel Notgroschen 5.000 €'
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE id = v_idw AND status = 'working') THEN
    RAISE EXCEPTION 'FAIL [3 ersetzen]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE section_key = 'risk_profile' AND status = 'open') <> 1 THEN
    RAISE EXCEPTION 'FAIL [3 anderer Abschnitt angefasst]'; END IF;
  -- Ohne handoff_tasks gespeichert (Prosa-Korrektur) -> die offenen bleiben; ausdruecklich leere Liste -> sie entfallen
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein','section_content','y'));
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE section_key = 'risk_profile' AND status = 'open') <> 1 THEN RAISE EXCEPTION 'FAIL [3 ohne Parameter geloescht]'; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','risk_profile','topic','Allgemein','section_content','y','handoff_tasks','[]'));
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE section_key = 'risk_profile') <> 0 THEN RAISE EXCEPTION 'FAIL [3 leere Liste]'; END IF;
  -- Mitglied darf nicht speichern (owner_only) -> keine Aufgaben
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','222','section_key','risk_profile','topic','Allgemein',
         'section_content','x','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','t'))));
  IF (r->>'ok')::boolean IS NOT FALSE OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE person_id = 'lena') THEN
    RAISE EXCEPTION 'FAIL [3 Mitglied]: %', r; END IF;
  RAISE NOTICE 'PASS [3 Neu-Speichern ersetzt nur offene]';

  -- ---------- 4) Uebersicht ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building','topic','Allgemein',
         'section_content','z','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','recurring_transfer','text','Dauerauftrag 100 € aufs Tagesgeld'))));
  SELECT max(id) INTO v_id3 FROM agent.handoff_tasks;
  SELECT id INTO v_id1 FROM agent.handoff_tasks WHERE section_key = 'goals_triggers' AND status = 'open';
  r := core.fn_handoff_overview('{"domain":"finance","chat_id":"111"}');
  IF (r->>'count')::int <> 2 OR (r->>'max_task_id')::int <> v_id3 OR r->'items'->>0 <> 'Sparziel Notgroschen 5.000 €'
     OR r->'items'->>1 <> 'Dauerauftrag 100 € aufs Tagesgeld' THEN RAISE EXCEPTION 'FAIL [4 Uebersicht]: %', r; END IF;
  -- fertige Text-Struktur fuer beide Sender (Abfolge und Berater-Tool)
  IF r->'msg'->>'kind' <> 'tpl' OR r->'msg'->>'value' <> 'core.handoff.overview'
     OR r->'msg'->'params'->>'list' <> E'1. Sparziel Notgroschen 5.000 €\n2. Dauerauftrag 100 € aufs Tagesgeld' THEN RAISE EXCEPTION 'FAIL [4 msg]: %', r; END IF;
  r := core.fn_handoff_overview('{"domain":"finance","chat_id":"222"}');
  IF (r->>'count')::int <> 0 OR r->'max_task_id' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL [4 andere Person]: %', r; END IF;
  -- ein abgelaufener working-Claim (Lauf abgebrochen) erscheint wieder in der Uebersicht
  UPDATE agent.handoff_tasks SET claimed_at = now() - interval '3 hours' WHERE id = v_idw;
  r := core.fn_handoff_overview('{"domain":"finance","chat_id":"111"}');
  IF (r->>'count')::int <> 3 THEN RAISE EXCEPTION 'FAIL [4 abgelaufener Claim]: %', r; END IF;
  UPDATE agent.handoff_tasks SET claimed_at = now() WHERE id = v_idw;
  RAISE NOTICE 'PASS [4 Uebersicht]';

  -- ---------- 5) Handler ----------
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_id3,'chat_id','111','chat_type','group'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r ? 'route' OR r->>'toast' <> 'DE:core.toast.plan_private_only' THEN RAISE EXCEPTION 'FAIL [5 Gruppe]: %', r; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_id3,'chat_id','222','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' <> 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [5 Mitglied]: %', r; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:estate:' || v_id3,'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' <> 'DE:core.toast.area_unavailable' THEN RAISE EXCEPTION 'FAIL [5 Domain]: %', r; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:1 OR 1=1','chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5 manipuliert]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE status = 'working' AND id <> v_idw) THEN RAISE EXCEPTION 'FAIL [5 Ablehnung beanspruchte]'; END IF;
  -- veraltetes max: nur bis max beanspruchen (eine spaeter angelegte Aufgabe bleibt offen)
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_id1,'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'handoff' OR r->>'domain' <> 'finance'
     OR r->'task_ids' <> jsonb_build_array(v_id1) OR r->'tasks'->0->>'text' <> 'Sparziel Notgroschen 5.000 €'
     OR r->'tasks'->0->>'kind' <> 'savings_goal' THEN RAISE EXCEPTION 'FAIL [5 Owner]: %', r; END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_id3) <> 'open' THEN RAISE EXCEPTION 'FAIL [5 max ueberschritten]'; END IF;
  -- Doppeltipp -> nichts mehr offen
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_id1,'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' <> 'DE:core.toast.handoff_nothing_open' THEN RAISE EXCEPTION 'FAIL [5 Doppeltipp]: %', r; END IF;
  -- Re-Claim nach der TTL (Default 120 min): der haengende working-Claim v_idw wird mitgenommen
  UPDATE agent.handoff_tasks SET claimed_at = now() - interval '3 hours' WHERE id = v_idw;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_id3,'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->'task_ids' <> jsonb_build_array(v_idw, v_id3) THEN RAISE EXCEPTION 'FAIL [5 TTL]: %', r; END IF;
  -- Ende-zu-Ende ueber den Dispatcher (Mitglied: member_permeable -> Handler-Toast)
  r := core.fn_dispatch_callback(jsonb_build_object('data','handoff:finance:' || v_id3,'chat_id','222','chat_type','private'));
  IF r ? 'route' OR r->>'toast' <> 'EN:core.toast.plan_owner_only' THEN RAISE EXCEPTION 'FAIL [5 Dispatcher Mitglied]: %', r; END IF;
  RAISE NOTICE 'PASS [5 Handler]';

  -- ---------- 6) Freigabe bei Dispatch-Fehler ----------
  r := core.fn_release_handoff_tasks(jsonb_build_object('task_ids', jsonb_build_array(v_id3)));
  IF (r->>'released')::int <> 1 OR (SELECT status FROM agent.handoff_tasks WHERE id = v_id3) <> 'open'
     OR (SELECT claimed_at FROM agent.handoff_tasks WHERE id = v_id3) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [6 release]: %', r; END IF;
  r := core.fn_dispatch_callback(jsonb_build_object('data','handoff:finance:' || v_id3,'chat_id','111','chat_type','private'));
  IF r->>'route' <> 'handoff' OR r->'task_ids' <> jsonb_build_array(v_id3) THEN RAISE EXCEPTION 'FAIL [6 Dispatcher Owner]: %', r; END IF;
  RAISE NOTICE 'PASS [6 Freigabe + Dispatcher]';

  -- ---------- 7) Lesen, Pruefen, Abschliessen ----------
  r := core.fn_handoff_tasks_read(ARRAY[v_id1, v_id3, 999999]);
  IF jsonb_array_length(r) <> 2 OR r->0->>'id' <> v_id1::text OR r->0->>'status' <> 'working' OR r->1->>'kind' <> 'recurring_transfer' THEN
    RAISE EXCEPTION 'FAIL [7 read]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_id1, 'chat_id', '222'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [7 fremde Person]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', 'x', 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 keine Zahl]: %', r; END IF;
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_id1, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'text' <> 'Sparziel Notgroschen 5.000 €' THEN RAISE EXCEPTION 'FAIL [7 check]: %', r; END IF;
  r := core.fn_complete_handoff_task(jsonb_build_object('handoff_task_id', v_id1, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM agent.handoff_tasks WHERE id = v_id1) <> 'done'
     OR (SELECT closed_at FROM agent.handoff_tasks WHERE id = v_id1) IS NULL THEN RAISE EXCEPTION 'FAIL [7 complete]: %', r; END IF;
  r := core.fn_complete_handoff_task(jsonb_build_object('handoff_task_id', v_id1, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 zweimal]: %', r; END IF;
  -- offene (nicht beanspruchte) Aufgabe ist nicht abschliessbar
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','retirement_pension','topic','Allgemein',
         'section_content','r','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','Rentenbescheid hochladen'))));
  SELECT id INTO v_id2 FROM agent.handoff_tasks WHERE section_key = 'retirement_pension';
  r := core.fn_handoff_task_check(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [7 open]: %', r; END IF;
  RAISE NOTICE 'PASS [7 read/check/complete]';

  -- ---------- 8) Ueberspringen / anderweitig erledigt ----------
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id3, 'chat_id', '222', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 fremde Person]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id3, 'chat_id', '111', 'reason', 'later'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 reason]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id3, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'cancelled' OR r->>'text' <> 'Dauerauftrag 100 € aufs Tagesgeld'
     OR (SELECT status FROM agent.handoff_tasks WHERE id = v_id3) <> 'cancelled' THEN RAISE EXCEPTION 'FAIL [8 skipped]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id2, 'chat_id', '111', 'reason', 'done_elsewhere'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'status' <> 'done' THEN RAISE EXCEPTION 'FAIL [8 done_elsewhere aus open]: %', r; END IF;
  r := core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_id3, 'chat_id', '111', 'reason', 'skipped'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8 schon geschlossen]: %', r; END IF;
  RAISE NOTICE 'PASS [8 cancel]';

  -- ---------- 9) Gesetz: Endzustand unveraenderlich, CHECKs ----------
  BEGIN
    UPDATE agent.handoff_tasks SET status = 'open', closed_at = NULL WHERE id = v_id1;
    RAISE EXCEPTION 'FAIL [9 Endzustand geaendert]';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance','finance','erika','x','other', repeat('b', 301));
    RAISE EXCEPTION 'FAIL [9 CHECK text]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status) VALUES ('finance','finance','erika','x','other','t','working');
    RAISE EXCEPTION 'FAIL [9 CHECK claim]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status) VALUES ('finance','finance','erika','x','other','t','done');
    RAISE EXCEPTION 'FAIL [9 CHECK closed]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- DELETE eines Endzustands bleibt erlaubt (Purge/E2E)
  DELETE FROM agent.handoff_tasks WHERE id = v_id1;
  RAISE NOTICE 'PASS [9 Gesetz]';

  -- ---------- 10) E2E-Sentinel-Domain: nicht-numerische chat_id -> Owner, Cleanup ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__e2e_finance__','chat_id','test_e2e_x','section_key','goals_triggers','topic','Allgemein',
         'section_content','e','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','__E2E__ t'))));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT person_id || '/' || package FROM agent.handoff_tasks WHERE domain = '__e2e_finance__') <> 'erika/finance' THEN
    RAISE EXCEPTION 'FAIL [10 e2e save]: %', r; END IF;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'other', '__E2E__ Testfall-Aufgabe der echten Domain');
  r := agent.fn_clear_e2e_data();
  IF (r->>'handoff_tasks')::int <> 2 OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text LIKE '%\_\_E2E%') OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE domain = '__e2e_finance__') THEN
    RAISE EXCEPTION 'FAIL [10 e2e cleanup]: %', r; END IF;
  RAISE NOTICE 'PASS [10 E2E-Domain]';

  -- ---------- 11) Themen: ein Themen-Save ersetzt die offenen Aufgaben seines Themas plus die themenlosen ----------
  DELETE FROM agent.handoff_tasks;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('finance', 'finance', 'erika', 'wealth_building', 'other', 'Vor den Themen vereinbart');
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building',
         'topic','Aufteilung','section_content','a','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','savings_plan','text','Sparplan 150 € Welt-ETF'))));
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building',
         'topic','Steuer','section_content','s','handoff_tasks', jsonb_build_array(jsonb_build_object('kind','other','text','Freistellungsauftrag stellen'))));
  IF (SELECT count(*) FROM agent.handoff_tasks WHERE section_key = 'wealth_building' AND status = 'open') <> 2
     OR EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE topic IS NULL)
     OR (SELECT topic FROM agent.handoff_tasks WHERE text = 'Sparplan 150 € Welt-ETF') <> 'Aufteilung' THEN
    RAISE EXCEPTION 'FAIL [11 je Thema]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  -- dasselbe Thema anders geschrieben ersetzt nur seine eigene Aufgabe
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','finance','chat_id','111','section_key','wealth_building',
         'topic','aufteilung','section_content','a2','handoff_tasks', '[]'));
  IF EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text = 'Sparplan 150 € Welt-ETF')
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE text = 'Freistellungsauftrag stellen' AND status = 'open') THEN
    RAISE EXCEPTION 'FAIL [11 Thema ersetzt]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text) VALUES ('finance','finance','erika','x', repeat('t', 61), 'other','t');
    RAISE EXCEPTION 'FAIL [11 CHECK topic]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS [11 Aufgaben je Thema]';END $$;

ROLLBACK;
