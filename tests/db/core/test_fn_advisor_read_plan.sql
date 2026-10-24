-- tests/db/core/test_fn_advisor_read_plan.sql
-- core.fn_advisor_read_plan(domain, chat_id) PERSON-SCOPE (P0c + P2b-2 Isolations-Verschluss):
--   per_user-Domain (career) -> der Plan-Read ist PRO PERSON. chat_id numerisch -> fn_resolve_sender -> dessen
--   person_id -> dessen Plan. KEIN/nicht-numerischer chat_id -> Owner-Fallback (fn_owner_person_id). Die zentrale
--   Isolations-Aussage: Person B (chat_id 222 -> lena) bekommt B's Plan, NIE A's (Owner erika) -> "B sieht A NICHT".
--   (Das gebundene read_plan-Tool des career_advisor ruft GENAU diese fn mit der build-fixen chat_id.)
-- db_test seedet KEIN context_scopes -> die per_user-Zeile career_planning wird hier selbst geseedet (sonst
--   COALESCE -> household -> person_id NULL -> kein Person-Scope). core.advisors leer -> plan_context-Fallback
--   '<domain>_planning' = 'career_planning'. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;
DO $$
DECLARE v_md text; v_cnt int;
BEGIN
  -- Fixture: family owner(erika 111) + partner(lena 222) -> agent.persons (FK + fn_resolve_sender/owner).
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, managed_by, package)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
      jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))),
    'agent','core')
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- career_planning ist per_user (P0c) — in db_test selbst seeden.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';

  -- Je Person ein DISTINKTER aktiver Plan (verschiedenes plan_md -> die Isolation ist am Inhalt pruefbar).
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES
    ('career','erika','Erika Plan','active',1,'{"targets":{"content":"E"}}'::jsonb,'ERIKA PLAN MD'),
    ('career','lena', 'Lena Plan', 'active',1,'{"targets":{"content":"L"}}'::jsonb,'LENA PLAN MD');

  -- TEST 1: chat_id 111 -> erika -> erikas Plan
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career','111');
  IF v_md IS DISTINCT FROM 'ERIKA PLAN MD' THEN RAISE EXCEPTION 'FAIL [1] chat_id 111 (erika) erwartet ERIKA, got %', v_md; END IF;
  RAISE NOTICE 'PASS [1] Person A (chat_id) -> A''s Plan';

  -- TEST 2: chat_id 222 -> lena -> LENAS Plan, NIE erikas (DAS Isolations-Leck, das P2b-2 schliesst)
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career','222');
  IF v_md IS DISTINCT FROM 'LENA PLAN MD' THEN RAISE EXCEPTION 'FAIL [2] chat_id 222 (lena) erwartet LENA, got % (ISOLATIONS-LECK: B sieht A!)', v_md; END IF;
  -- haerter: lena darf erikas Plan unter KEINEN Umstaenden im Result haben
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career','222') WHERE plan_md = 'ERIKA PLAN MD';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [2b] lena-Read enthaelt erikas Plan (Leck)'; END IF;
  RAISE NOTICE 'PASS [2] Person B -> B''s Plan, NIE A''s (Isolation)';

  -- TEST 3: kein chat_id -> Owner-Fallback (erika)
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career', NULL);
  IF v_md IS DISTINCT FROM 'ERIKA PLAN MD' THEN RAISE EXCEPTION 'FAIL [3] NULL chat_id erwartet Owner-Fallback (erika), got %', v_md; END IF;
  RAISE NOTICE 'PASS [3] kein chat_id -> Owner-Fallback (P0c Single-Person)';

  -- TEST 4: nicht-numerischer chat_id -> Owner-Fallback (kein RAISE, kein Cast auf bigint)
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career', 'notanumber');
  IF v_md IS DISTINCT FROM 'ERIKA PLAN MD' THEN RAISE EXCEPTION 'FAIL [4] nicht-numerischer chat_id erwartet Owner-Fallback, got %', v_md; END IF;
  RAISE NOTICE 'PASS [4] nicht-numerischer chat_id -> Owner-Fallback (kein RAISE)';
END $$;
ROLLBACK;
