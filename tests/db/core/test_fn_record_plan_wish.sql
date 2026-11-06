-- tests/db/core/test_fn_record_plan_wish.sql
-- agent.fn_record_plan_wish(p): "Wunsch an den Owner" (2026-10-28) — ein erwachsenes Mitglied (partner) speichert einen
-- Aenderungswunsch zum AKTIVEN Haushalts-Plan der Domain, Wortlaut in Originalsprache. Probelauf (dry_run) vor der
-- HITL-Karte ueber core.fn_dry_run (zurueckgerollt); Ablehnungen als {ok:false, reason} ohne RAISE.
BEGIN;

DO $$
DECLARE
  v     jsonb;
  v_pid int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222),
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
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');

  -- (1) kein aktiver Plan -> Ablehnung, auch im Probelauf
  v := agent.fn_record_plan_wish('{"domain":"finance","chat_id":"222","wish_text":"Mehr Notgroschen"}');
  IF (v->>'ok')::boolean IS NOT FALSE OR v->>'reason' IS NULL THEN RAISE EXCEPTION 'FAIL [1 kein Plan]: %', v; END IF;

  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 2, '{}', 'p') RETURNING id INTO v_pid;

  -- (2) Probelauf ueber core.fn_dry_run (wie die Tool-Karte): ok, aber zurueckgerollt
  v := core.fn_dry_run('agent.fn_record_plan_wish(jsonb)'::regprocedure, '{"domain":"finance","chat_id":"222","wish_text":"Mehr Notgroschen"}');
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->>'plan_version')::int <> 2 THEN RAISE EXCEPTION 'FAIL [2 dry_run]: %', v; END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plan_wishes) THEN RAISE EXCEPTION 'FAIL [2 dry_run schrieb]'; END IF;

  -- (3) Write: Wortlaut unveraendert, plan_id = aktive Version, Handle zurueck
  v := agent.fn_record_plan_wish('{"domain":"finance","chat_id":"222","wish_text":"  더 많은 비상금을 원해요  "}');
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->>'plan_id')::int <> v_pid OR (v->>'wish_id') IS NULL OR (v->>'plan_version')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [3 write]: %', v; END IF;
  IF (SELECT wish_text FROM agent.advisor_plan_wishes WHERE id = (v->>'wish_id')::int) <> '더 많은 비상금을 원해요'
     OR (SELECT person_id FROM agent.advisor_plan_wishes WHERE id = (v->>'wish_id')::int) <> 'lena' THEN
    RAISE EXCEPTION 'FAIL [3 gespeichert]'; END IF;

  -- (4) Ablehnungen: Owner, Kind, unbekannt, leer, zu lang, persoenlicher Plan
  IF (agent.fn_record_plan_wish('{"domain":"finance","chat_id":"111","wish_text":"x"}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 Owner]'; END IF;
  IF (agent.fn_record_plan_wish('{"domain":"finance","chat_id":"333","wish_text":"x"}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 Kind]'; END IF;
  IF (agent.fn_record_plan_wish('{"domain":"finance","chat_id":"999","wish_text":"x"}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 unbekannt]'; END IF;
  IF (agent.fn_record_plan_wish('{"domain":"finance","chat_id":"222","wish_text":"   "}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 leer]'; END IF;
  IF (agent.fn_record_plan_wish(jsonb_build_object('domain','finance','chat_id','222','wish_text', repeat('a', 2001)))->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL [4 zu lang]'; END IF;
  IF (agent.fn_record_plan_wish('{"domain":"career","chat_id":"222","wish_text":"x"}')->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [4 career]'; END IF;
  IF (SELECT count(*) FROM agent.advisor_plan_wishes) <> 1 THEN RAISE EXCEPTION 'FAIL [4 Ablehnung schrieb]'; END IF;

  -- (5) CHECK als Backstop (direkter Insert umgeht die fn nicht)
  BEGIN
    INSERT INTO agent.advisor_plan_wishes (plan_id, person_id, wish_text) VALUES (v_pid, 'lena', '  ');
    RAISE EXCEPTION 'FAIL [5 CHECK leer]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  RAISE NOTICE 'PASS test_fn_record_plan_wish (Probelauf, Wortlaut, aktive Version, nur Partner, Laenge, CHECK)';
END $$;

ROLLBACK;
