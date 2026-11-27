-- tests/db/core/test_fn_advisor_progress.sql
-- Stand des Plan-Gespraechs: core.fn_advisor_progress + core.fn_advisor_parts + Zustand enter in
-- state enter, handoffs_open, part/parts_total in core.fn_advisor_plan_status.
--   * Teile und Etappen aus core.advisors.stages (CHECK auf die Form); ohne stages eine Etappe aus dem Katalog;
--   * Phasen none -> talk -> check -> publish -> enter -> done; mode fresh/existing; open_points; check {pass,total,done};
--     handoffs {total,done}; rollout_next check (erledigter Altbestand im gueltigen Plan, Pruef-Merker nicht festgeschrieben, kein Entwurf);
--   * stage_boundary wahr genau am ersten Teil einer neuen Etappe nach fertiger voriger, ohne Etappen nie;
--   * unaufgeloester Absender -> ok:false.
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r      jsonb;
  v_plan int;
  v_task int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.advisors WHERE domain IN ('__pg__', '__pg2__');
  -- Form-Gesetz der Etappen
  BEGIN
    INSERT INTO core.advisors (domain, plan_context, review_fn, package, stages)
    VALUES ('__pg__', '__pg___planning', 'finance.fn_advisor_review', 'finance', '[{"key":"basis"}]');
    RAISE EXCEPTION 'FAIL [0 stages ohne sections angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, stages) VALUES
    ('__pg__', '__pg___planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true,
     '[{"key":"basis","sections":["household_basics","emergency_reserve"]},{"key":"ziele","sections":["goals_triggers"]}]'),
    ('__pg2__', '__pg2___planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', false, NULL);
  DELETE FROM agent.advisor_plans WHERE domain IN ('__pg__', '__pg2__');
  DELETE FROM agent.handoff_tasks WHERE domain = '__pg__';
  DELETE FROM agent.chat_prompts;

  -- ---------- 1) ohne Plan ----------
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','999'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [1 unaufgeloest]: %', r; END IF;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'none' OR r->>'mode' <> 'fresh' OR (r->>'parts_total')::int <> 3 OR (r->>'parts_done')::int <> 0
     OR r->>'current_key' <> 'household_basics' OR r->>'stage_current' <> 'basis' OR (r->>'stage_boundary')::boolean
     OR jsonb_array_length(r->'stages') <> 2 OR (r->>'open_points')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [1 none]: %', r; END IF;
  RAISE NOTICE 'PASS [1 ohne Plan]';

  -- ---------- 2) talk + Etappen-Grenze ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__pg__','chat_id','111','section_key','household_basics',
         'topic','Haushalt','section_content','Haushalt laut Daten bestätigt.'));
  v_plan := (r->>'plan_id')::int;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'talk' OR (r->>'parts_done')::int <> 1 OR r->>'current_key' <> 'emergency_reserve'
     OR (r->>'stage_boundary')::boolean OR r->>'mode' <> 'fresh' THEN
    RAISE EXCEPTION 'FAIL [2 talk]: %', r; END IF;
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__pg__','chat_id','111','section_key','emergency_reserve',
         'topic','Notgroschen','section_content','Drei Monatsausgaben.','open_points','["Konto wählen"]',
         'handoff_tasks','[{"kind":"savings_goal","text":"Sparziel Notgroschen"}]'));
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->'parts'->0->>'state' <> 'done' OR r->'parts'->0->>'headline' <> 'Haushalt' OR r->'parts'->2->>'state' <> 'current'
     OR r->'parts'->2->>'stage' <> 'ziele' OR r->'current'->>'section_key' <> 'goals_triggers' OR (r->'current'->>'n')::int <> 3 THEN
    RAISE EXCEPTION 'FAIL [2 parts + current]: %', r; END IF;
  IF (r->>'parts_done')::int <> 2 OR r->>'current_key' <> 'goals_triggers' OR r->>'stage_current' <> 'ziele'
     OR (r->>'stage_boundary')::boolean IS NOT TRUE OR (r->'stages'->0->>'done')::boolean IS NOT TRUE
     OR (r->'stages'->1->>'parts_done')::int <> 0 OR (r->>'open_points')::int <> 1
     OR (r->'handoffs'->>'total')::int <> 1 OR (r->'handoffs'->>'done')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 Etappen-Grenze]: %', r; END IF;
  r := core.fn_advisor_plan_status('111');
  SELECT e INTO r FROM jsonb_array_elements(r) e WHERE e->>'domain' = '__pg__';
  IF r->>'state' <> 'draft' OR (r->>'part')::int <> 3 OR (r->>'parts_total')::int <> 3 THEN RAISE EXCEPTION 'FAIL [2 plan_status Teil]: %', r; END IF;
  RAISE NOTICE 'PASS [2 talk + Etappen-Grenze]';

  -- ---------- 3) check -> publish ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__pg__','chat_id','111','section_key','goals_triggers',
         'topic','Ziele','section_content','Ein Ziel: Rente.'));
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'check' OR r->>'current_key' IS NOT NULL OR (r->>'stage_boundary')::boolean
     OR (r->'check'->>'pass')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [3 check ohne Durchgang]: %', r; END IF;
  INSERT INTO agent.chat_prompts (chat_id, person_id, agent, kind, plan_id, ord, status, answer_key, decided_at, options, payload) VALUES
    ('111','erika','agent.finance_advisor','finding', v_plan, 0, 'answered', 'go', now(), '[{"key":"go","label":"x"}]', '{"pass":1,"role":"overview"}'),
    ('111','erika','agent.finance_advisor','finding', v_plan, 1, 'open', NULL, NULL, '[{"key":"keep","label":"x"}]', '{"pass":1,"category":"contradiction"}');
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'check' OR (r->'check'->>'pass')::int <> 1 OR (r->'check'->>'total')::int <> 1 OR (r->'check'->>'done')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [3 check offen]: %', r; END IF;
  UPDATE agent.chat_prompts SET status = 'answered', answer_key = 'keep', decided_at = now() WHERE status = 'open';
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'publish' OR (r->'check'->>'done')::int <> 1 THEN RAISE EXCEPTION 'FAIL [3 publish]: %', r; END IF;
  -- ein Punkt hat Themen geaendert -> zweiter Durchgang steht noch aus
  UPDATE agent.chat_prompts SET payload = payload || '{"changed":true}' WHERE answer_key = 'keep';
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'check' THEN RAISE EXCEPTION 'FAIL [3 zweiter Durchgang ausstehend]: %', r; END IF;
  RAISE NOTICE 'PASS [3 check + publish]';

  -- ---------- 4) enter -> done, Plan-Status ----------
  UPDATE agent.advisor_plans SET status = 'active', plan_md = 'x' WHERE id = v_plan;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'enter' OR (r->'handoffs'->>'total')::int <> 1 OR r->>'mode' <> 'existing' THEN
    RAISE EXCEPTION 'FAIL [4 enter]: %', r; END IF;
  r := core.fn_advisor_plan_status('111');
  SELECT e INTO r FROM jsonb_array_elements(r) e WHERE e->>'domain' = '__pg__';
  IF r->>'state' <> 'enter' OR (r->>'handoffs_open')::int <> 1 OR r->>'part' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 plan_status enter]: %', r; END IF;
  -- Zeitachse: Plan und Aufgabe stammen von gestern (der neue Entwurf in 5 zaehlt nur seine eigenen Aufgaben)
  UPDATE agent.advisor_plans SET created_at = created_at - interval '1 day' WHERE id = v_plan;
  UPDATE agent.handoff_tasks SET created_at = created_at - interval '1 day' WHERE domain = '__pg__';
  SELECT id INTO v_task FROM agent.handoff_tasks WHERE domain = '__pg__';
  UPDATE agent.handoff_tasks SET status = 'done', closed_at = now() WHERE id = v_task;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'phase' <> 'done' OR (r->'handoffs'->>'done')::int <> 1 THEN RAISE EXCEPTION 'FAIL [4 done]: %', r; END IF;
  r := core.fn_advisor_plan_status('111');
  SELECT e INTO r FROM jsonb_array_elements(r) e WHERE e->>'domain' = '__pg__';
  IF r->>'state' <> 'complete' OR (r->>'handoffs_open')::int <> 0 THEN RAISE EXCEPTION 'FAIL [4 plan_status complete]: %', r; END IF;
  RAISE NOTICE 'PASS [4 enter + done]';

  -- ---------- 4b) naechster Schritt der Abfolge: erledigter Altbestand ohne Provenienz, Abschnitt im gueltigen Plan -> check,
  --           bis der Pruef-Merker festgeschrieben ist (danach bietet core.fn_plan_rollout_next ihn nicht mehr an) ----------
  UPDATE agent.advisor_plans SET synced_at = now() WHERE id = v_plan;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'rollout_next' IS DISTINCT FROM 'check' THEN RAISE EXCEPTION 'FAIL [4b check offen]: %', r->>'rollout_next'; END IF;
  -- Vorher kommende Schritte der Abfolge: ein offener Eintrag der Person (auch einer von vor der Plan-Zeile) haelt den Pruef-Schritt auf
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, created_at)
  VALUES ('__pg__', 'finance', 'erika', 'goals_triggers', 'other', 'Alt offen', now() - interval '30 days');
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'rollout_next' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4b offener Eintrag zuerst]: %', r->>'rollout_next'; END IF;
  DELETE FROM agent.handoff_tasks WHERE domain = '__pg__' AND text = 'Alt offen';
  -- ... ebenso [Plan durchsehen] (Schritt 0), solange der Plan nicht durchgesehen ist und das Paket es verlangt
  INSERT INTO core.config (category, key, value, package) VALUES ('advisor', 'plan_sync_required', 'true', 'finance')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true', package = 'finance';
  UPDATE agent.advisor_plans SET synced_at = NULL WHERE id = v_plan;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'rollout_next' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4b Plan durchsehen zuerst]: %', r->>'rollout_next'; END IF;
  UPDATE agent.advisor_plans SET synced_at = now() WHERE id = v_plan;
  -- Haushaltsplan: Schritte bekommt nur der Owner
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', (metadata->'facts'->'persons') || jsonb_build_array(
    jsonb_build_object('person_id','max','first_name','Max','last_name','M','role','partner','birth_date','1982-02-02','telegram_user_id',222,'language','de')))
   WHERE name = 'family';
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','222'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'rollout_next' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4b Mitglied]: %', r; END IF;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'rollout_next' IS DISTINCT FROM 'check' THEN RAISE EXCEPTION 'FAIL [4b wieder check]: %', r->>'rollout_next'; END IF;
  INSERT INTO core.notification_state (source, key, state, last_fired_at, expires_at)
  VALUES ('plan_rollout', '__pg__:household:check:' || v_task, 'fired', now(), now() + interval '30 minutes');
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'rollout_next' IS DISTINCT FROM 'check' THEN RAISE EXCEPTION 'FAIL [4b beansprucht zaehlt noch]: %', r->>'rollout_next'; END IF;
  UPDATE core.notification_state SET expires_at = NULL WHERE source = 'plan_rollout' AND key = '__pg__:household:check:' || v_task;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r ? 'rollout_next' AND r->>'rollout_next' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4b festgeschrieben]: %', r->>'rollout_next'; END IF;
  DELETE FROM core.notification_state WHERE source = 'plan_rollout' AND key = '__pg__:household:check:' || v_task;
  RAISE NOTICE 'PASS [4b rollout_next check]';

  -- ---------- 5) Bestandsplan = mode existing ----------
  r := agent.fn_advisor_save_section(jsonb_build_object('domain','__pg__','chat_id','111','section_key','household_basics',
         'topic','Haushalt','section_content','Unverändert.'));
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg__','chat_id','111'));
  IF r->>'mode' <> 'existing' OR r->>'phase' <> 'talk' OR (r->>'parts_done')::int <> 1 OR (r->'handoffs'->>'total')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [5 existing]: %', r; END IF;
  -- offener Entwurf: die Abfolge wartet (core.fn_plan_rollout_next), also kein naechster Schritt, auch mit ungepruefem Altbestand
  IF r->>'rollout_next' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 Entwurf ohne rollout_next]: %', r->>'rollout_next'; END IF;
  RAISE NOTICE 'PASS [5 mode existing]';

  -- ---------- 6) ohne stages: eine Etappe aus dem Katalog ----------
  INSERT INTO core.ui_texts (key, lang, text, package)
  SELECT 'finance.plan_section.' || k, 'de', k, 'finance' FROM unnest(ARRAY['household_basics','goals_triggers']) k
  ON CONFLICT (key, lang) DO NOTHING;
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg2__','chat_id','111'));
  IF jsonb_array_length(r->'stages') <> 1 OR r->'stages'->0->>'key' <> 'all' OR (r->>'stage_boundary')::boolean
     OR (r->>'parts_total')::int < 2 THEN
    RAISE EXCEPTION 'FAIL [6 ohne stages]: %', r; END IF;
  RAISE NOTICE 'PASS [6 ohne stages]';

  -- ---------- 7) Abschnitte als Objekte (Anbauten) ----------
  UPDATE core.advisors SET stages = '[{"key":"basis","sections":["household_basics",{"key":"annex_beliefs","annex":true,"slot":"left"}]}]' WHERE domain = '__pg2__';
  r := core.fn_advisor_progress(jsonb_build_object('domain','__pg2__','chat_id','111'));
  IF (r->>'parts_total')::int <> 2 OR r->'parts'->1->>'key' <> 'annex_beliefs' OR (r->'parts'->1->>'annex')::boolean IS NOT TRUE
     OR r->'parts'->1->>'slot' <> 'left' THEN
    RAISE EXCEPTION 'FAIL [7 Objekt-Abschnitte]: %', r; END IF;
  BEGIN
    UPDATE core.advisors SET stages = '[{"key":"basis","sections":[{"slot":"left"}]}]' WHERE domain = '__pg2__';
    RAISE EXCEPTION 'FAIL [7 Objekt ohne key angenommen]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS [7 Objekt-Abschnitte]';
END $$;

ROLLBACK;
