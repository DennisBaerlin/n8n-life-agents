-- tests/db/core/test_fn_advisor_resume_due.sql
-- core.fn_advisor_resume_due(p): Erinnerung an eine angefangene Beratung (Stufe 1 nach 4, Stufe 2 nach 14 Tagen, dann
-- Ruhe) und einmal an offene Uebergabe-Punkte nach dem Veroeffentlichen. Je Zeile der Zustands-Matrix ein Fall:
--   Z0/Z2/Z3 nichts; Z4 Stufe 1; Z5 Ueberarbeitung; Z6 Stufe 2; Z7 Ruhe; Z8 Re-Arm (mit Mindestabstand); Z9 nichts;
--   Z10 nichts; Z11 einmal je hoechster Aufgabe, nicht vor 14 Tagen, nicht ohne Rollout-Merker, nicht bei offenem
--   Abschnitt; Thema-Etikett (Thema / Abschnitts-Name / keins); offene Punkte im Entwurf; offener fremder Abschnitt +
--   Entwurf -> Erinnerung (R6 mit "Angefangenes geht vor"); R7 Gruss-Vorschlag heute; R8 Denk-Schalter / offene Karte;
--   rem:off und Notschalter vor jedem Merker; ready=false; Paket inaktiv; Mitglied mit eigenem Entwurf nie;
--   Quellen-Grenze (onboarding_nudge heute); ausserhalb des Erinnerungs-Fensters nichts; neuer Entwurf = neue Merker.
-- db_test hat kein seed_data -> Personen, Registry, Berater, Texte self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_order jsonb := '["core:household","finance:accounts"]';
  p_in    jsonb := jsonb_build_object('order', '["core:household","finance:accounts"]'::jsonb, 'plan_order', '["finance","career"]'::jsonb);
  r       jsonb;
  it      jsonb;
  v_id    int;
  v_id2   int;
  v_max   int;
  h       int := extract(hour FROM now())::int;
BEGIN
  -- ---------- Fixtures ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','de'),
    jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','B','role','child','birth_date','2014-03-02','telegram_user_id',333,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  UPDATE core.package_registry SET status = 'inactive' WHERE package NOT IN ('core', 'finance', 'career');
  DELETE FROM core.context_scopes WHERE package IN ('career', 'finance');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning', 'per_user', 'own_user_only', 'career');
  UPDATE agent.guide_onboarding_state SET status = 'completed';
  DELETE FROM finance.onboarding_state;
  INSERT INTO finance.onboarding_state (section_key, ord, label, status) VALUES ('accounts', 1, 'Konten', 'completed');
  DELETE FROM career.onboarding_state;
  CREATE FUNCTION finance.fn_t_ready(text, text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT COALESCE(NULLIF(current_setting('t.ready', true), ''), '{"ready":true,"missing":[]}')::jsonb $f$;
  CREATE FUNCTION finance.fn_t_gaps(text, text) RETURNS int LANGUAGE sql AS $f$ SELECT 2 $f$;
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, readiness_fn) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, 'finance.fn_t_ready'),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true, NULL);
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.advisor_plans;
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('advisor_resume', 'core', 'person', true)
    ON CONFLICT (cron_key) DO UPDATE SET scope = 'person', default_enabled = true;
  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'cron_enable', 'advisor_resume', 'true'), ('core', 'general', 'reminders_from', '0'), ('core', 'general', 'reminders_until', '24')
    ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  DELETE FROM core.config WHERE category = 'advisor' AND key LIKE 'resume_%';
  DELETE FROM core.notification_state WHERE source IN ('advisor_resume', 'onboarding_nudge', 'plan_rollout', 'next_step_day');
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred; DELETE FROM agent.reminder_pause;
  DELETE FROM agent.thinking_lease; DELETE FROM agent.hitl_pending;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('finance.plan_section.emergency_reserve', 'de', 'Notgroschen', 'finance')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  ALTER TABLE agent.advisor_plans DISABLE TRIGGER trg_advisor_plans_touch;

  -- ---------- (1) Z0 nie begonnen -> nichts; ok:true, items leer ----------
  r := core.fn_advisor_resume_due(p_in);
  IF r->>'ok' <> 'true' OR jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [1 Z0]: %', r; END IF;

  -- ---------- (2) Z2 laeuft (1 h) / Z3 ruht kurz (3 Tage) -> nichts ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('finance', NULL, 'Plan', 'draft', 1, '{}', now() - interval '1 hour') RETURNING id INTO v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [2 Z2]: %', r; END IF;
  UPDATE agent.advisor_plans SET updated_at = now() - interval '3 days' WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [2 Z3]: %', r; END IF;

  -- ---------- (3) Z4 ruht 5 Tage, erster Plan -> Stufe 1, Knoepfe, Merker; ohne Thema leerer Teilsatz ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '5 days' WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 1 THEN RAISE EXCEPTION 'FAIL [3 ein Item]: %', r; END IF;
  it := r->'items'->0;
  IF it->>'person_id' <> 'erika' OR (it->>'chat_id')::bigint <> 111 OR it->>'kind' <> 'draft' OR (it->>'stage')::int <> 1
     OR it->>'domain' <> 'finance' OR it->>'package' <> 'finance' OR (it->>'plan_id')::int <> v_id OR (it->>'revision')::boolean
     OR (it->>'open_tasks')::int <> 0
     OR it->'msg'->0->>'value' <> 'core.advisor_resume.stage1' OR jsonb_array_length(it->'msg') <> 1
     OR it->'msg'->0->'params'->'plan'->>'value' <> 'finance.plan.name' OR it->'msg'->0->'params'->>'topic_part' <> ''
     OR it->'buttons'->0->>'text_key' <> 'core.nudge.btn_continue' OR it->'buttons'->0->>'data' <> ('plan:resume:finance:' || v_id)
     OR jsonb_array_length(it->'buttons') <> 1 THEN
    RAISE EXCEPTION 'FAIL [3 Z4 Stufe 1]: %', it; END IF;
  IF NOT core.fn_notify_told('advisor_resume', 'erika:finance:' || v_id || ':1') THEN RAISE EXCEPTION 'FAIL [3 Merker]'; END IF;
  -- Gruss-Merker unberuehrt (R7: der Versand schreibt nichts in die Merker des naechsten Schritts)
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source LIKE 'next_step%') THEN RAISE EXCEPTION 'FAIL [3 next_step-Merker beschrieben]'; END IF;

  -- ---------- (4) gleich nochmal -> nichts ----------
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [4 kein Doppel]: %', r; END IF;

  -- ---------- (5) Z6: Stillstand 15 Tage, Stufe 1 vor 8 Tagen -> Stufe 2 ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '15 days' WHERE id = v_id;
  UPDATE core.notification_state SET last_fired_at = now() - interval '8 days' WHERE source = 'advisor_resume';
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF (it->>'stage')::int IS DISTINCT FROM 2 OR it->'msg'->0->>'value' <> 'core.advisor_resume.stage2' THEN RAISE EXCEPTION 'FAIL [5 Z6]: %', r; END IF;

  -- ---------- (6) Z7 danach Ruhe, auch viel spaeter (Z9 ab 30 Tagen ohnehin) ----------
  DELETE FROM core.proactive_budget;
  UPDATE agent.advisor_plans SET updated_at = now() - interval '25 days' WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [6 Z7]: %', r; END IF;

  -- ---------- (7) Z8 wieder aufgenommen: Stufe 2 erst vor 5 Tagen -> keine neue Stufe; vor 20 Tagen -> Stufe 1 neu ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '5 days' WHERE source = 'advisor_resume' AND key LIKE '%:2';
  UPDATE agent.advisor_plans SET updated_at = now() - interval '4 days' WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [7 Re-Arm vor Mindestabstand]: %', r; END IF;
  UPDATE core.notification_state SET last_fired_at = now() - interval '30 days' WHERE source = 'advisor_resume' AND key LIKE '%:1';
  UPDATE core.notification_state SET last_fired_at = now() - interval '20 days' WHERE source = 'advisor_resume' AND key LIKE '%:2';
  r := core.fn_advisor_resume_due(p_in);
  IF (r->'items'->0->>'stage')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [7 Z8 Re-Arm]: %', r; END IF;

  -- ---------- (8) Z9 Entwurf 31 Tage -> nichts ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_resume';
  DELETE FROM core.proactive_budget;
  UPDATE agent.advisor_plans SET updated_at = now() - interval '31 days' WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [8 Z9]: %', r; END IF;

  -- ---------- (9) Thema-Etikett: juengstes Thema / juengster Abschnitt ohne Thema mit Katalog-Name / unbekannter Abschnitt ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '5 days', interview_state = jsonb_build_object(
      'emergency_reserve', jsonb_build_object('content', 'x', 'saved_at', now() - interval '9 days'),
      'insurance', jsonb_build_object('saved_at', now() - interval '8 days', 'topics', jsonb_build_array(
          jsonb_build_object('topic', 'Haftpflicht', 'content', 'y', 'saved_at', now() - interval '6 days'),
          jsonb_build_object('topic', 'Hausrat', 'content', 'z', 'saved_at', now() - interval '7 days'))))
   WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF it->'msg'->0->'params'->'topic_part'->>'value' <> 'core.advisor_resume.topic_part'
     OR it->'msg'->0->'params'->'topic_part'->'params'->>'topic' <> 'Haftpflicht' THEN
    RAISE EXCEPTION 'FAIL [9 Thema]: %', it; END IF;
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  UPDATE agent.advisor_plans SET interview_state = jsonb_set(interview_state, '{emergency_reserve,saved_at}', to_jsonb(now() - interval '5 days')) WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF it->'msg'->0->'params'->'topic_part'->'params'->'topic'->>'value' <> 'finance.plan_section.emergency_reserve' THEN
    RAISE EXCEPTION 'FAIL [9 Abschnitts-Name]: %', it; END IF;
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  UPDATE agent.advisor_plans SET interview_state = jsonb_build_object('zz_unknown', jsonb_build_object('content', 'x', 'saved_at', now() - interval '5 days')) WHERE id = v_id;
  r := core.fn_advisor_resume_due(p_in);
  IF r->'items'->0->'msg'->0->'params'->>'topic_part' <> '' THEN RAISE EXCEPTION 'FAIL [9 ohne Etikett]: %', r; END IF;

  -- ---------- (10) offene Uebergabe-Punkte im Entwurf -> Zusatzsatz mit Zahl aus der DB ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance', 'finance', 'erika', 'goals', 'savings_goal', 'Ziel A'), ('finance', 'finance', 'erika', 'goals', 'savings_plan', 'Plan B');
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF (it->>'open_tasks')::int <> 2 OR it->'msg'->1->>'value' <> 'core.advisor_resume.open_tasks' OR (it->'msg'->1->'params'->>'n')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [10 zwei Punkte]: %', it; END IF;
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  DELETE FROM agent.handoff_tasks WHERE text = 'Plan B';
  r := core.fn_advisor_resume_due(p_in);
  IF r->'items'->0->'msg'->1->>'value' <> 'core.advisor_resume.open_task_one' THEN RAISE EXCEPTION 'FAIL [10 ein Punkt]: %', r; END IF;
  DELETE FROM agent.handoff_tasks;

  -- ---------- (11) Z5 Ueberarbeitung (aktiver Plan + Entwurf) -> E1-Ue ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md, updated_at)
  VALUES ('finance', NULL, 'Plan', 'active', 7, '{}', 'p', now() - interval '60 days');
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF NOT (it->>'revision')::boolean OR it->'msg'->0->>'value' <> 'core.advisor_resume.stage1_revision' THEN RAISE EXCEPTION 'FAIL [11 Z5]: %', it; END IF;
  DELETE FROM agent.advisor_plans WHERE status = 'active';

  -- ---------- (12) R6: offener fremder Abschnitt + Entwurf -> Erinnerung kommt (Angefangenes geht vor) ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  UPDATE finance.onboarding_state SET status = 'unknown';
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 1 THEN RAISE EXCEPTION 'FAIL [12 R6 erfuellt]: %', r; END IF;
  -- ready=false -> naechster Schritt ist der fehlende Abschnitt -> nichts
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  PERFORM set_config('t.ready', '{"ready":false,"missing":[{"key":"a","section":"accounts"}]}', true);
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [12 ready=false]: %', r; END IF;
  PERFORM set_config('t.ready', '', true);
  UPDATE finance.onboarding_state SET status = 'completed';

  -- ---------- (13) R7: heute schon ein Gruss-Vorschlag -> nichts, unverbraucht ----------
  INSERT INTO core.notification_state (source, key, state, last_fired_at)
  VALUES ('next_step_day', 'erika:' || to_char(core.fn_today(), 'YYYY-MM-DD') || ':1', 'fired', now());
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 OR core.fn_notify_told('advisor_resume', 'erika:finance:' || v_id || ':1') THEN RAISE EXCEPTION 'FAIL [13 R7]: %', r; END IF;
  DELETE FROM core.notification_state WHERE source = 'next_step_day';

  -- ---------- (14) R8: Denk-Schalter lebt / offene Karte -> nichts, unverbraucht ----------
  INSERT INTO agent.thinking_lease (execution_id, chat_id, expires_at) VALUES ('t-exec-1', 111, now() + interval '1 minute');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [14 Denk-Schalter]: %', r; END IF;
  DELETE FROM agent.thinking_lease;
  INSERT INTO agent.hitl_pending (chat_id, execution_id, expires_at) VALUES (111, 't-exec-2', now() + interval '1 hour');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 OR core.fn_notify_told('advisor_resume', 'erika:finance:' || v_id || ':1') THEN RAISE EXCEPTION 'FAIL [14 Karte offen]: %', r; END IF;
  DELETE FROM agent.hitl_pending;

  -- ---------- (15) rem:off / Notschalter -> nichts, keine Stufe verbraucht ----------
  INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled) VALUES ('erika', 'advisor_resume', false);
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 OR EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'advisor_resume') THEN
    RAISE EXCEPTION 'FAIL [15 rem:off]: %', r; END IF;
  DELETE FROM agent.reminder_prefs;
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'advisor_resume';
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [15 Notschalter]: %', r; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'advisor_resume';

  -- ---------- (16) Quellen-Grenze: Einrichtungs-Erinnerung heute schon an diese Person -> nichts, unverbraucht ----------
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('onboarding_nudge', 'erika:1', 'fired', now());
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 OR core.fn_notify_told('advisor_resume', 'erika:finance:' || v_id || ':1') THEN RAISE EXCEPTION 'FAIL [16 Quellen-Grenze]: %', r; END IF;
  DELETE FROM core.notification_state WHERE source = 'onboarding_nudge';

  -- ---------- (17) ausserhalb des Erinnerungs-Fensters -> nichts ----------
  UPDATE core.config SET value = CASE key WHEN 'reminders_from' THEN (CASE WHEN h < 23 THEN h + 1 ELSE 0 END)::text
                                         ELSE (CASE WHEN h < 23 THEN h + 2 ELSE 1 END)::text END
   WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [17 Fenster]: %', r; END IF;
  UPDATE core.config SET value = CASE key WHEN 'reminders_from' THEN '0' ELSE '24' END WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');

  -- ---------- (18) Paket inaktiv -> nichts ----------
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [18 Paket inaktiv]: %', r; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'finance';

  -- ---------- (19) Mitglied mit eigenem Karriere-Entwurf direkt in der DB -> nie; Kind nie ----------
  DELETE FROM agent.advisor_plans;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at) VALUES
    ('career', 'lena', 'K', 'draft', 1, '{}', now() - interval '5 days'),
    ('career', 'lisa', 'K', 'draft', 1, '{}', now() - interval '5 days');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [19 Mitglied/Kind]: %', r; END IF;

  -- ---------- (20) persoenlicher Plan des Owners (career) -> Item mit plan_id; neuer Entwurf = neue Merker ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('career', 'erika', 'K', 'draft', 1, '{}', now() - interval '5 days') RETURNING id INTO v_id;
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF it->>'domain' <> 'career' OR it->'msg'->0->'params'->'plan'->>'value' <> 'career.plan.name' OR (it->>'plan_id')::int <> v_id THEN
    RAISE EXCEPTION 'FAIL [20 career]: %', r; END IF;
  DELETE FROM agent.advisor_plans WHERE id = v_id;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('career', 'erika', 'K', 'draft', 2, '{}', now() - interval '5 days') RETURNING id INTO v_id2;
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_resume_due(p_in);
  IF (r->'items'->0->>'plan_id')::int IS DISTINCT FROM v_id2 OR (r->'items'->0->>'stage')::int <> 1 THEN RAISE EXCEPTION 'FAIL [20 neuer Entwurf]: %', r; END IF;
  DELETE FROM agent.advisor_plans;

  -- ---------- (21) Z10 veroeffentlicht mit Luecken, keine Punkte -> nichts ----------
  DELETE FROM core.notification_state WHERE source = 'advisor_resume'; DELETE FROM core.proactive_budget;
  UPDATE core.advisors SET gaps_fn = 'finance.fn_t_gaps' WHERE domain = 'finance';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md, updated_at)
  VALUES ('finance', NULL, 'Plan', 'active', 1, '{}', 'p', now() - interval '60 days');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [21 Z10]: %', r; END IF;

  -- ---------- (22) Z11 offene Uebergabe-Punkte nach dem Veroeffentlichen ----------
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    ('finance', 'finance', 'erika', 'goals', 'savings_goal', 'Ziel A'), ('finance', 'finance', 'erika', 'goals', 'savings_plan', 'Plan B');
  SELECT max(id) INTO v_max FROM agent.handoff_tasks;
  -- ohne Rollout-Merker -> nichts
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 ohne Rollout-Liste]: %', r; END IF;
  -- Rollout-Liste vor 5 Tagen -> noch nicht
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('plan_rollout', 'finance:household:handoff:' || v_max, 'fired', now() - interval '5 days');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 vor 14 Tagen]: %', r; END IF;
  -- vor 15 Tagen, aber offener Abschnitt -> nichts (R6: kind section)
  UPDATE core.notification_state SET last_fired_at = now() - interval '15 days' WHERE source = 'plan_rollout';
  UPDATE finance.onboarding_state SET status = 'unknown';
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 offener Abschnitt]: %', r; END IF;
  UPDATE finance.onboarding_state SET status = 'completed';
  -- jetzt -> einmal
  r := core.fn_advisor_resume_due(p_in);
  it := r->'items'->0;
  IF jsonb_array_length(r->'items') <> 1 OR it->>'kind' <> 'handoff' OR (it->>'max_task_id')::int <> v_max OR (it->>'open_tasks')::int <> 2
     OR it->'msg'->0->>'value' <> 'core.handoff.overview' OR it->'msg'->0->'params'->'why'->>'value' <> 'core.handoff.why_resume'
     OR it->'buttons'->0->>'text_key' <> 'core.handoff.btn_go' OR it->'buttons'->0->>'data' <> ('handoff:finance:' || v_max)
     OR jsonb_array_length(it->'buttons') <> 1 THEN
    RAISE EXCEPTION 'FAIL [22 Z11]: %', it; END IF;
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 nur einmal]: %', r; END IF;
  -- neue Aufgabe (hoehere max_task_id): erst nach der naechsten Rollout-Liste moeglich
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance', 'finance', 'erika', 'goals', 'other', 'C');
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 neue Aufgabe ohne neue Liste]: %', r; END IF;
  -- Entwurf derselben Domain -> Z11 schweigt (Entwurfs-Fall statt Uebergabe)
  SELECT max(id) INTO v_max FROM agent.handoff_tasks;
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('plan_rollout', 'finance:household:handoff:' || v_max, 'fired', now() - interval '15 days');
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('finance', NULL, 'Plan', 'draft', 2, '{}', now() - interval '1 day');
  DELETE FROM core.proactive_budget;
  r := core.fn_advisor_resume_due(p_in);
  IF jsonb_array_length(r->'items') <> 0 THEN RAISE EXCEPTION 'FAIL [22 Entwurf -> keine Uebergabe-Erinnerung]: %', r; END IF;

  ALTER TABLE agent.advisor_plans ENABLE TRIGGER trg_advisor_plans_touch;
  RAISE NOTICE 'PASS test_fn_advisor_resume_due (Z0-Z11, Thema-Etikett, offene Punkte, R6/R7/R8, rem:off, Notschalter, Quellen-Grenze, Fenster, Paket inaktiv, Mitglied/Kind, neuer Entwurf)';
END $$;

ROLLBACK;
