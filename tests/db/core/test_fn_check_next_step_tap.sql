-- tests/db/core/test_fn_check_next_step_tap.sql
-- core.fn_check_next_step_tap(p): ein ':next'-Knopf startet nur, wenn er noch der aktuelle Schritt des Tippenden ist;
--   ein Zuerst-Abschnitt (uebersprungen) bleibt gueltig; ein Kind kann keinen career-Knopf nutzen; gueltiger Tipp setzt den
--   Wiederholungs-Zaehler zurueck; Knoepfe ohne Suffix bleiben unveraendert; core.fn_handle_onboarding_cb nimmt den
--   4. Teil ':next' in jedem Zweig hin (split_part liest nur Teil 2 und 3).
BEGIN;

DO $$
DECLARE
  v_order jsonb := '["core:household","finance:accounts","career:profile_basics"]';
  r jsonb;
  s jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','B','role','child','birth_date','2014-03-02','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE package IN ('career', 'finance');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES ('career_profile', 'per_user', 'own_user_only', 'career');
  DELETE FROM finance.onboarding_state;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('accounts', 1, 'Konten');
  DELETE FROM career.onboarding_state;
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id, status, for_roles)
  VALUES ('profile_basics', 1, 'Profil', 'erika', 'completed', '{owner,partner}');
  DELETE FROM core.advisors;
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES ('core.toast.step_done', 'de', 'Schon erledigt.', 'core')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  DELETE FROM core.notification_state WHERE source = 'next_step_offer';

  -- ---------- (1) ohne Suffix: unveraendert durch ----------
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '111', 'data', 'onboarding:finance:accounts', 'order', v_order));
  IF r->>'ok' <> 'true' OR r->>'data' <> 'onboarding:finance:accounts' THEN RAISE EXCEPTION 'FAIL [1 ohne Suffix]: %', r; END IF;

  -- ---------- (2) aktueller Schritt -> ok, Suffix weg, Zaehler zurueck ----------
  s := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order));
  PERFORM core.fn_claim_next_step_offer(jsonb_build_object('chat_id', '111', 'callback', s->>'callback', 'state', s->>'state',
                                                           'generation', s->'generation', 'smalltalk', 'greeting'));
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'next_step_offer' AND state = 'fired') THEN
    RAISE EXCEPTION 'FAIL [2 Vorbedingung Zaehler]'; END IF;
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '111', 'data', 'onboarding:core:household:next', 'order', v_order));
  IF r->>'ok' <> 'true' OR r->>'data' <> 'onboarding:core:household' THEN RAISE EXCEPTION 'FAIL [2 aktuell]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'next_step_offer' AND state = 'fired') THEN
    RAISE EXCEPTION 'FAIL [2 Zaehler nicht zurueck]'; END IF;

  -- ---------- (3) Schritt inzwischen erledigt -> stale + Toast ----------
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '111', 'data', 'onboarding:core:household:next', 'order', v_order));
  IF r->>'ok' <> 'false' OR r->>'reason' <> 'stale' OR r->>'toast' <> 'Schon erledigt.' THEN RAISE EXCEPTION 'FAIL [3 veraltet]: %', r; END IF;

  -- ---------- (4) Zuerst-Abschnitt (uebersprungen) bleibt gueltig ----------
  UPDATE finance.onboarding_state SET status = 'skipped';
  CREATE FUNCTION finance.fn_t_ready_tap(text, text) RETURNS jsonb LANGUAGE sql AS $f$
    SELECT '{"ready":false,"missing":[{"key":"a","section":"accounts"}]}'::jsonb $f$;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan', jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO NOTHING;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, NULL, 'finance.fn_t_ready_tap');
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '111', 'data', 'onboarding:finance:accounts:next', 'order', v_order,
                                                      'plan_order', '["finance"]'::jsonb));
  IF r->>'ok' <> 'true' OR r->>'data' <> 'onboarding:finance:accounts' THEN RAISE EXCEPTION 'FAIL [4 Zuerst gueltig]: %', r; END IF;

  -- ---------- (5) Kind tippt einen career-Knopf -> abgewiesen; unbekannt -> abgewiesen ----------
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '333', 'data', 'onboarding:career:profile_basics:next', 'order', v_order));
  IF r->>'ok' <> 'false' THEN RAISE EXCEPTION 'FAIL [5 Kind]: %', r; END IF;
  r := core.fn_check_next_step_tap(jsonb_build_object('chat_id', '999', 'data', 'onboarding:core:household:next'));
  IF r->>'ok' <> 'false' THEN RAISE EXCEPTION 'FAIL [5 unbekannt]: %', r; END IF;

  -- ---------- (6) Mitglieder-Handler: 4. Teil ':next' stoert keinen Zweig ----------
  -- Kind + for_roles {owner,partner}: der Handler weist den Bereich ab (auch ohne Suffix); for_roles NULL -> erlaubt
  r := core.fn_handle_onboarding_cb(jsonb_build_object('data', 'onboarding:career:profile_basics:next', 'chat_id', '333', 'chat_type', 'private'));
  IF r->>'reason' IS DISTINCT FROM 'not_for_role' THEN RAISE EXCEPTION 'FAIL [6 career Kind]: %', r; END IF;
  UPDATE career.onboarding_state SET for_roles = NULL;
  r := core.fn_handle_onboarding_cb(jsonb_build_object('data', 'onboarding:career:profile_basics:next', 'chat_id', '333', 'chat_type', 'private'));
  IF r->>'ok' <> 'true' THEN RAISE EXCEPTION 'FAIL [6 career :next, for_roles NULL]: %', r; END IF;
  r := core.fn_handle_onboarding_cb(jsonb_build_object('data', 'onboarding:core:household:next', 'chat_id', '333', 'chat_type', 'private'));
  IF r->>'reason' <> 'owner_only' THEN RAISE EXCEPTION 'FAIL [6 Haushalt :next Mitglied]: %', r; END IF;
  r := core.fn_handle_onboarding_cb(jsonb_build_object('data', 'onboarding:_area:finance:next', 'chat_id', '333', 'chat_type', 'private'));
  IF r->>'ok' <> 'true' THEN RAISE EXCEPTION 'FAIL [6 _area :next]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_check_next_step_tap (ohne Suffix, aktuell + Zaehler zurueck, veraltet, Zuerst gueltig, Kind, unbekannt, Handler)';
END $$;

ROLLBACK;
