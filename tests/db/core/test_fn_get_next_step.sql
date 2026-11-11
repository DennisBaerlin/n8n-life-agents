-- tests/db/core/test_fn_get_next_step.sql
-- core.fn_get_next_step(p) + core.fn_get_next_step_example(person_id, order): der EINE naechste Schritt je Person.
-- Je Zeile der Zustands-Matrix (.claude/plans/ux-paket-a-next-step.md) ein Fall:
--   Owner: Haushalt -> Abschnitt in order-Reihenfolge -> Plan in plan_order-Reihenfolge (reif / Zuerst / Drift) -> none;
--   Mitglied: wait solange der Haushalt offen ist, nur per_user-Abschnitte mit Rolle in for_roles, nie ein Plan;
--   unbekannter Absender -> none ohne Beispiel; Beispielfrage nur aus einer sicher angelegten Paket-fn mit gueltigem
--   Katalog-Key, sonst neutral; callback_data > 64 Byte -> kein Knopf; der Plan-Status wird nur fuer den Owner ohne
--   offenen Abschnitt gelesen (Zaehler ueber set_config, kein Write in der STABLE-Kette).
-- db_test hat kein seed_data -> Sektionen, Registry, Texte self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_order jsonb := '["core:household","finance:goals","finance:accounts","estate:documents","career:profile_basics","career:skills_overview"]';
  v       jsonb;
  ex      text;
  long_key text := 'k' || repeat('x', 60);
BEGIN
  -- ---------- Fixtures ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en'),
    jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','B','role','child','birth_date','2014-03-02','telegram_user_id',333,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active'), ('estate','0.1.0','installed')
  ON CONFLICT (package) DO UPDATE SET status = EXCLUDED.status;
  DELETE FROM core.context_scopes WHERE package IN ('career', 'finance');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile', 'per_user', 'own_user_only', 'career'), ('career_planning', 'per_user', 'own_user_only', 'career');

  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  DELETE FROM finance.onboarding_state;
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES ('accounts', 1, 'Konten'), ('goals', 6, 'Ziele');
  DELETE FROM career.onboarding_state;
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id, status, for_roles) VALUES
    ('profile_basics', 1, 'Profil', 'erika', 'completed', '{owner,partner}'),
    ('skills_overview', 2, 'Skills', 'erika', 'completed', '{owner,partner}');

  -- Plan-Schritt: finance (Haushalt) + career (persoenlich); readiness/gaps als Test-fns mit Zaehler
  CREATE FUNCTION finance.fn_t_ready(text, text) RETURNS jsonb LANGUAGE plpgsql AS $f$
  BEGIN
    PERFORM set_config('t.calls', (COALESCE(NULLIF(current_setting('t.calls', true), ''), '0')::int + 1)::text, true);
    RETURN COALESCE(NULLIF(current_setting('t.ready', true), ''), '{"ready":true,"missing":[]}')::jsonb;
  END $f$;
  CREATE FUNCTION finance.fn_t_gaps(text, text) RETURNS int LANGUAGE sql AS $f$ SELECT 2 $f$;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan', jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO NOTHING;
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, 'finance.fn_t_gaps', 'finance.fn_t_ready'),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true, NULL, NULL);
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');

  -- Texte (db_test seedet keinen Katalog)
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('core.onboarding.household', 'de', 'Haushalt', 'core'),
    ('core.onboarding.menu.btn_next', 'de', 'Weiter: {label}', 'core'),
    ('core.onboarding.menu.btn_next', 'en', 'Next: {label}', 'core'),
    ('core.onboarding.menu.btn_first', 'de', 'Zuerst: {label}', 'core'),
    ('core.next_step.example_neutral', 'de', 'Was kannst du alles?', 'core'),
    ('core.next_step.example_neutral', 'en', 'What can you do?', 'core'),
    ('finance.onboarding.accounts', 'de', 'Konten', 'finance'),
    ('finance.onboarding.goals', 'de', 'Ziele', 'finance'),
    ('finance.package.name', 'de', 'Finanzen', 'finance'),
    ('finance.plan_step.btn_none', 'de', 'Finanzplan erstellen', 'finance'),
    ('finance.plan_step.btn_gaps', 'de', 'Plan vervollständigen ({open} offen)', 'finance'),
    ('finance.next_step.example', 'de', 'Wie viel Geld haben wir?', 'finance'),
    ('finance.next_step.example', 'en', 'How much money do we have?', 'finance'),
    ('career.onboarding.profile_basics', 'de', 'Berufsprofil', 'career'),
    ('career.onboarding.profile_basics', 'en', 'Career profile', 'career'),
    ('career.plan_step.btn_none', 'de', 'Karriereplan erstellen', 'career')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  -- Paket-Beispiel-fn (Vertrag fuer Paket B): Key nur mit Haushalts-Sicht
  CREATE OR REPLACE FUNCTION finance.fn_next_step_example(p_person_id text) RETURNS text
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$
  BEGIN
    RETURN CASE WHEN core.fn_app_sees_household(p_person_id) THEN COALESCE(NULLIF(current_setting('t.ex_key', true), ''), 'finance.next_step.example') END;
  END $f$;

  -- ---------- (1) Owner, Haushalt offen -> Haushalt; Plan-Status nicht gelesen ----------
  PERFORM set_config('t.calls', '0', true);
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'ok' <> 'true' OR v->>'kind' <> 'section' OR v->>'callback' <> 'onboarding:core:household'
     OR v->>'data' <> 'onboarding:core:household:next' OR v->>'label' <> 'Haushalt'
     OR v->>'button' <> (U&'\+01F449' || ' Weiter: Haushalt') OR v->>'role' <> 'owner' OR (v->>'sees_household')::boolean IS NOT TRUE
     OR v->>'state' <> 'open' THEN
    RAISE EXCEPTION 'FAIL [1 Owner Haushalt]: %', v; END IF;
  IF current_setting('t.calls', true) <> '0' THEN RAISE EXCEPTION 'FAIL [1 Plan-Status gelesen]: %', current_setting('t.calls', true); END IF;
  -- Beispielfrage nur bei Bedarf: offener Schritt mit Knopf-Angebot -> keine, mit with_example -> die des Pakets
  IF v->>'example' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 Beispiel ohne Bedarf berechnet]: %', v; END IF;
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'with_example', true));
  IF v->>'example' IS DISTINCT FROM 'Wie viel Geld haben wir?' THEN RAISE EXCEPTION 'FAIL [1 with_example]: %', v; END IF;

  -- ---------- (2) Haushalt fertig -> erster offener Abschnitt laut order (goals vor accounts, gegen ord) ----------
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'section' OR v->>'callback' <> 'onboarding:finance:goals' OR v->>'package' <> 'finance' OR v->>'key' <> 'goals' THEN
    RAISE EXCEPTION 'FAIL [2 order]: %', v; END IF;
  IF current_setting('t.calls', true) <> '0' THEN RAISE EXCEPTION 'FAIL [2 Plan-Status bei offenem Abschnitt gelesen]'; END IF;

  -- ---------- (3) alles erledigt, Plan reif -> erster laut plan_order (nicht ORDER BY domain) ----------
  UPDATE finance.onboarding_state SET status = 'skipped';
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'plan' OR v->>'callback' <> 'plan:finance' OR v->>'data' <> 'plan:finance' OR v->>'domain' <> 'finance'
     OR v->>'label' <> 'Finanzplan erstellen' OR v->>'button' <> (U&'\+01F449' || ' Weiter: Finanzplan erstellen') OR v->>'state' <> 'none' THEN
    RAISE EXCEPTION 'FAIL [3 Plan finance]: %', v; END IF;
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["career","finance"]'::jsonb));
  IF v->>'callback' <> 'plan:career' THEN RAISE EXCEPTION 'FAIL [3 plan_order umgekehrt]: %', v; END IF;

  -- ---------- (4) aktiver Plan mit Luecken -> {open} ersetzt ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 1, '{}', 'p');
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'state' <> 'gaps' OR v->>'label' <> 'Plan vervollständigen (2 offen)' OR (v->>'generation')::bigint <= 0 THEN
    RAISE EXCEPTION 'FAIL [4 gaps]: %', v; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';

  -- ---------- (5) Mindestdaten fehlen (Abschnitt uebersprungen) -> Zuerst: <Abschnitt> mit :next ----------
  PERFORM set_config('t.ready', '{"ready":false,"missing":[{"key":"accounts_min","section":"accounts"}]}', true);
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'plan' OR v->>'state' <> 'first' OR v->>'callback' <> 'onboarding:finance:accounts'
     OR v->>'data' <> 'onboarding:finance:accounts:next' OR v->>'button' <> (U&'\+01F449' || ' Zuerst: Konten') THEN
    RAISE EXCEPTION 'FAIL [5 Zuerst]: %', v; END IF;

  -- ---------- (6) Drift: fehlender Abschnitt unbekannt -> Bereich ----------
  PERFORM set_config('t.ready', '{"ready":false,"missing":[{"key":"x","section":"zzz"}]}', true);
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'callback' <> 'onboarding:_area:finance' OR v->>'label' <> 'Finanzen' THEN RAISE EXCEPTION 'FAIL [6 Drift]: %', v; END IF;
  PERFORM set_config('t.ready', '', true);

  -- ---------- (7) alle Plaene komplett -> none + Paket-Beispiel ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 1, '{}', 'p'), ('career', 'erika', 'K', 'active', 1, '{}', 'k');
  UPDATE core.advisors SET gaps_fn = NULL WHERE domain = 'finance';
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'none' OR v->>'example' <> 'Wie viel Geld haben wir?' OR v ? 'button' AND v->>'button' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [7 none + Beispiel]: %', v; END IF;

  -- ---------- (8) Partner: per_user-Abschnitt mit Rolle in for_roles; nie ein Plan; Sprache en ----------
  PERFORM set_config('t.calls', '0', true);
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '222', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'section' OR v->>'callback' <> 'onboarding:career:profile_basics' OR v->>'label' <> 'Career profile'
     OR v->>'button' <> (U&'\+01F449' || ' Next: Career profile') OR v->>'role' <> 'partner' THEN
    RAISE EXCEPTION 'FAIL [8 Partner per_user]: %', v; END IF;
  UPDATE career.onboarding_state SET for_roles = '{owner}';
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '222', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'none' OR v->>'example' <> 'How much money do we have?' THEN RAISE EXCEPTION 'FAIL [8 Partner ausserhalb for_roles / nie Plan]: %', v; END IF;
  IF current_setting('t.calls', true) <> '0' THEN RAISE EXCEPTION 'FAIL [8 Plan-Status fuer Mitglied gelesen]'; END IF;
  UPDATE career.onboarding_state SET for_roles = '{owner,partner}';

  -- ---------- (9) Kind: career nicht fuer child -> none, kein Geld-Beispiel -> neutral ----------
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '333', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'none' OR v->>'example' <> 'Was kannst du alles?' OR (v->>'sees_household')::boolean IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [9 Kind]: %', v; END IF;
  -- for_roles NULL = alle Rollen -> das Kind bekommt den Abschnitt
  UPDATE career.onboarding_state SET for_roles = NULL;
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '333', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'callback' <> 'onboarding:career:profile_basics' THEN RAISE EXCEPTION 'FAIL [9 for_roles NULL = alle]: %', v; END IF;
  UPDATE career.onboarding_state SET for_roles = '{owner,partner}';

  -- ---------- (10) Mitglied bei offenem Haushalt -> wait, kein Beispiel ----------
  UPDATE agent.guide_onboarding_state SET status = 'unknown' WHERE section_key = 'household';
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '222', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'kind' <> 'wait' OR v->>'example' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [10 wait]: %', v; END IF;
  UPDATE agent.guide_onboarding_state SET status = 'completed' WHERE section_key = 'household';

  -- ---------- (11) unbekannter / ungueltiger Absender -> none ohne Beispiel, ok:true ----------
  FOREACH ex IN ARRAY ARRAY['999', 'abc', ''] LOOP
    v := core.fn_get_next_step(jsonb_build_object('chat_id', ex, 'order', v_order));
    IF v->>'ok' <> 'true' OR v->>'kind' <> 'none' OR v->>'example' IS NOT NULL OR v->>'role' IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL [11 unbekannt %]: %', ex, v; END IF;
  END LOOP;
  v := core.fn_get_next_step('{}'::jsonb);
  IF v->>'kind' <> 'none' THEN RAISE EXCEPTION 'FAIL [11 leere Eingabe]: %', v; END IF;

  -- ---------- (12) Beispiel-fn: nur sicher angelegt, nur gueltiger paket-eigener Key ----------
  ex := core.fn_get_next_step_example('erika', v_order);
  IF ex <> 'Wie viel Geld haben wir?' THEN RAISE EXCEPTION 'FAIL [12 Basis]: %', ex; END IF;
  PERFORM set_config('t.ex_key', 'finance.next_step.unknown', true);
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 unbekannter Key]'; END IF;
  PERFORM set_config('t.ex_key', 'core.next_step.example_neutral', true);
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 paketfremder Key]'; END IF;
  PERFORM set_config('t.ex_key', '', true);
  ALTER FUNCTION finance.fn_next_step_example(text) SECURITY INVOKER;
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 ohne DEFINER aufgerufen]'; END IF;
  ALTER FUNCTION finance.fn_next_step_example(text) SECURITY DEFINER;
  ALTER FUNCTION finance.fn_next_step_example(text) RESET search_path;
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 ohne search_path aufgerufen]'; END IF;
  ALTER FUNCTION finance.fn_next_step_example(text) SET search_path = pg_catalog, pg_temp;
  CREATE ROLE t_next_step_np NOLOGIN;
  ALTER FUNCTION finance.fn_next_step_example(text) OWNER TO t_next_step_np;
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 fremder Eigentuemer aufgerufen]'; END IF;
  ALTER FUNCTION finance.fn_next_step_example(text) OWNER TO CURRENT_USER;
  CREATE OR REPLACE FUNCTION finance.fn_next_step_example(p_person_id text) RETURNS text
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$ BEGIN RAISE EXCEPTION 'boom'; END $f$;
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 werfende fn]'; END IF;
  -- inaktives Paket wird nicht gefragt
  CREATE OR REPLACE FUNCTION finance.fn_next_step_example(p_person_id text) RETURNS text
  LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, pg_temp AS $f$ BEGIN RETURN 'finance.next_step.example'; END $f$;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  IF core.fn_get_next_step_example('erika', v_order) <> 'Was kannst du alles?' THEN RAISE EXCEPTION 'FAIL [12 inaktives Paket gefragt]'; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'finance';
  IF core.fn_get_next_step_example(NULL, v_order) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [12 ohne Person]'; END IF;

  -- ---------- (13) callback_data > 64 Byte -> kein Knopf (Telegram lehnt den Send sonst ab) ----------
  INSERT INTO finance.onboarding_state (section_key, ord, label) VALUES (long_key, 9, 'Lang');
  v := core.fn_get_next_step(jsonb_build_object('chat_id', '111', 'order', v_order, 'plan_order', '["finance","career"]'::jsonb));
  IF v->>'key' <> long_key OR v->>'button' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [13 Ueberlaenge]: %', v; END IF;

  RAISE NOTICE 'PASS test_fn_get_next_step (Haushalt, order, plan_order, gaps, Zuerst, Drift, none+Beispiel, Partner/for_roles, Kind, wait, unbekannt, Beispiel-fn-Schutz, 64 Byte)';
END $$;

ROLLBACK;
