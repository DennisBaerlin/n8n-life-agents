-- tests/db/core/test_fn_plan_share_targets.sql
-- Plan teilen (2026-10-28): erwachsene Mitglieder ueber einen neuen Haushalts-Plan informieren.
--   core.fn_plan_adult_recipients(domain)          = die EINE Empfaenger-Regel (partner, Chat, plan_news erlaubt)
--   core.fn_plan_share_preview(domain, version, chat) = Owner-Karte nach dem Publish (shareable + Namen)
--   core.fn_plan_share_targets(p)                  = Versand-Liste (read-only, schon Informierte = already)
--   core.fn_plan_share_mark(p)                     = zugestellte Sends merken (einmal je Person und Plan-Version)
BEGIN;

DO $$
DECLARE
  v      jsonb;
  v_pid  int;
BEGIN
  -- ---------- Fixtures: Owner erika (111, de), Partnerin lena (222, ko), Partner tom (444, de), Kind kim (333) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','ko'),
    jsonb_build_object('person_id','tom','first_name','Tom','last_name','B','role','partner','birth_date','1984-02-11','telegram_user_id',444,'language','de'),
    jsonb_build_object('person_id','kim','first_name','Kim','last_name','B','role','child','birth_date','2014-03-01','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name IN ('financial_planning', 'career_planning');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning', 'per_user', 'own_user_only', 'career');
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true);
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled, mandatory)
  VALUES ('plan_news', 'core', 'person', true, false)
  ON CONFLICT (cron_key) DO UPDATE SET scope = 'person', default_enabled = true;
  INSERT INTO core.config (package, category, key, value, description)
  VALUES ('core', 'cron_enable', 'plan_news', 'true', 't')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';
  DELETE FROM agent.reminder_prefs WHERE cron_key = 'plan_news';
  DELETE FROM core.notification_state WHERE source = 'plan_news';
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md, change_summary, change_summary_lang)
  VALUES ('finance', NULL, 'Plan', 'active', 3, '{}', 'p', 'Notgroschen auf 6 Monate erhoeht', 'de') RETURNING id INTO v_pid;

  -- ---------- (1) Empfaenger: nur Partner mit Chat (kein Owner, kein Kind), mit Sprache ----------
  IF (SELECT array_agg(person_id ORDER BY person_id) FROM core.fn_plan_adult_recipients('finance')) IS DISTINCT FROM ARRAY['lena','tom'] THEN
    RAISE EXCEPTION 'FAIL [1 Empfaenger]: %', (SELECT array_agg(person_id) FROM core.fn_plan_adult_recipients('finance')); END IF;
  IF (SELECT lang FROM core.fn_plan_adult_recipients('finance') WHERE person_id = 'lena') IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL [1 Sprache]'; END IF;
  -- persoenlicher Plan (career) hat keine Haushalts-Empfaenger
  IF EXISTS (SELECT 1 FROM core.fn_plan_adult_recipients('career')) THEN RAISE EXCEPTION 'FAIL [1 career]'; END IF;

  -- ---------- (2) Preview: Owner + aktuelle Version -> shareable mit Namen; sonst nicht ----------
  v := core.fn_plan_share_preview('finance', 3, '111');
  IF (v->>'shareable')::boolean IS NOT TRUE OR v->'names' <> '["Lena", "Tom"]'::jsonb THEN RAISE EXCEPTION 'FAIL [2 preview]: %', v; END IF;
  IF (core.fn_plan_share_preview('finance', 2, '111')->>'shareable')::boolean THEN RAISE EXCEPTION 'FAIL [2 alte Version]'; END IF;
  IF (core.fn_plan_share_preview('finance', 3, '222')->>'shareable')::boolean THEN RAISE EXCEPTION 'FAIL [2 Mitglied]'; END IF;
  IF (core.fn_plan_share_preview('career', 3, '111')->>'shareable')::boolean THEN RAISE EXCEPTION 'FAIL [2 career]'; END IF;

  -- ---------- (3) Targets (read-only): Summary nur bei gleicher Sprache; ohne Merken bleibt die Liste gleich ----------
  v := core.fn_plan_share_targets('{"domain":"finance","version":3,"chat_id":"111"}');
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(v->'targets') <> 2 OR (v->>'already')::int <> 0
     OR v->>'summary' <> 'Notgroschen auf 6 Monate erhoeht' OR (v->>'version')::int <> 3 OR v->>'package' <> 'finance'
     OR (v->>'plan_id')::int <> v_pid THEN
    RAISE EXCEPTION 'FAIL [3 erster Versand]: %', v; END IF;
  IF (SELECT (t->>'show_summary')::boolean FROM jsonb_array_elements(v->'targets') t WHERE t->>'person_id' = 'tom') IS NOT TRUE
     OR (SELECT (t->>'show_summary')::boolean FROM jsonb_array_elements(v->'targets') t WHERE t->>'person_id' = 'lena') IS NOT FALSE
     OR (SELECT t->>'chat_id' FROM jsonb_array_elements(v->'targets') t WHERE t->>'person_id' = 'lena') <> '222' THEN
    RAISE EXCEPTION 'FAIL [3 Summary je Sprache]: %', v; END IF;
  IF jsonb_array_length(core.fn_plan_share_targets('{"domain":"finance","version":3,"chat_id":"111"}')->'targets') <> 2 THEN
    RAISE EXCEPTION 'FAIL [3 read-only]'; END IF;

  -- ---------- (4) Merken nach erfolgreichem Send (nur tom zugestellt) -> lena bleibt offen; doppeltes Merken zaehlt nicht ----------
  v := core.fn_plan_share_mark(jsonb_build_object('domain','finance','plan_id', v_pid, 'person_ids', jsonb_build_array('tom')));
  IF (v->>'marked')::int <> 1 THEN RAISE EXCEPTION 'FAIL [4 mark]: %', v; END IF;
  IF (core.fn_plan_share_mark(jsonb_build_object('domain','finance','plan_id', v_pid, 'person_ids', jsonb_build_array('tom')))->>'marked')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL [4 mark doppelt]'; END IF;
  v := core.fn_plan_share_targets('{"domain":"finance","version":3,"chat_id":"111"}');
  IF jsonb_array_length(v->'targets') <> 1 OR v->'targets'->0->>'person_id' <> 'lena' OR (v->>'already')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL [4 nach Merken]: %', v; END IF;
  PERFORM core.fn_plan_share_mark(jsonb_build_object('domain','finance','plan_id', v_pid, 'person_ids', jsonb_build_array('lena')));
  v := core.fn_plan_share_targets('{"domain":"finance","version":3,"chat_id":"111"}');
  IF jsonb_array_length(v->'targets') <> 0 OR (v->>'already')::int <> 2 OR (v->>'none')::boolean THEN RAISE EXCEPTION 'FAIL [4 alle informiert]: %', v; END IF;

  -- ---------- (5) neue Plan-Version (neue plan_id) -> wieder informierbar; Abmeldung (plan_news aus) -> keine Empfaengerin ----------
  INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled) VALUES ('lena', 'plan_news', false)
  ON CONFLICT (person_id, cron_key) DO UPDATE SET enabled = false;
  UPDATE agent.advisor_plans SET status = 'superseded' WHERE id = v_pid;
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md, change_summary, change_summary_lang)
  VALUES ('finance', NULL, 'Plan', 'active', 4, '{}', 'p', 'Sparrate angepasst', 'de') RETURNING id INTO v_pid;
  v := core.fn_plan_share_targets('{"domain":"finance","version":4,"chat_id":"111"}');
  IF jsonb_array_length(v->'targets') <> 1 OR v->'targets'->0->>'person_id' <> 'tom' THEN RAISE EXCEPTION 'FAIL [5 neue Version/Abmeldung]: %', v; END IF;

  -- ---------- (6) Ablehnungen: veraltete Version, Mitglied, Notschalter aus -> niemand ----------
  v := core.fn_plan_share_targets('{"domain":"finance","version":3,"chat_id":"111"}');
  IF (v->>'ok')::boolean IS NOT FALSE OR v->>'reason' <> 'stale' THEN RAISE EXCEPTION 'FAIL [6 stale]: %', v; END IF;
  v := core.fn_plan_share_targets('{"domain":"finance","version":4,"chat_id":"222"}');
  IF (v->>'ok')::boolean IS NOT FALSE OR v->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL [6 Mitglied]: %', v; END IF;
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'plan_news';
  v := core.fn_plan_share_targets('{"domain":"finance","version":4,"chat_id":"111"}');
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(v->'targets') <> 0 OR (v->>'none')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [6 Notschalter]: %', v; END IF;
  RAISE NOTICE 'PASS test_fn_plan_share_targets (Partner-Regel, Preview, read-only Liste, Merken nach Send, Summary je Sprache, neue Version, Abmeldung, stale, Notschalter)';
END $$;

ROLLBACK;
