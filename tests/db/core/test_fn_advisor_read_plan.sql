-- tests/db/core/test_fn_advisor_read_plan.sql
-- core.fn_advisor_read_plan(domain, chat_id), Person-Scope:
--   per_user-Domain (career) -> der Plan-Read ist pro Person. chat_id numerisch -> fn_resolve_sender -> dessen
--   person_id -> dessen Plan. Kein/nicht-numerischer/unaufgeloester chat_id -> leere Menge (fail-closed, kein
--   Owner-Fallback). Aufruf aus einer Frei-SQL-Sitzung (Login-Rolle *_ro) -> leere Menge (chat_id dort
--   LLM-gesteuert). Die zentrale Isolations-Aussage: Person B (222 -> lena) bekommt B's Plan, nie A's (erika).
--   core_ro (Frei-SQL guide/monitor) liest agent.advisor_plans nicht; die RLS dahinter laesst nur Haushalts-Plaene
--   (person_id NULL) durch.
--   (Das gebundene read_plan-Tool des career_advisor ruft genau diese fn mit der build-fixen chat_id.)
-- db_test seedet kein context_scopes -> die per_user-Zeile career_planning wird hier selbst geseedet (sonst
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

  -- career_planning ist per_user — in db_test selbst seeden.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';

  -- Je Person ein distinkter aktiver Plan (verschiedenes plan_md -> die Isolation ist am Inhalt pruefbar) + ein
  -- Haushalts-Plan (person_id NULL) fuer die RLS-Gegenprobe.
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES
    ('career','erika','Erika Plan','active',1,'{"targets":{"content":"E"}}'::jsonb,'ERIKA PLAN MD'),
    ('career','lena', 'Lena Plan', 'active',1,'{"targets":{"content":"L"}}'::jsonb,'LENA PLAN MD'),
    ('__rp_household__', NULL, 'HH Plan', 'active',1,'{}'::jsonb,'HH PLAN MD');

  -- TEST 1: chat_id 111 -> erika -> erikas Plan
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career','111');
  IF v_md IS DISTINCT FROM 'ERIKA PLAN MD' THEN RAISE EXCEPTION 'FAIL [1] chat_id 111 (erika) erwartet ERIKA, got %', v_md; END IF;
  RAISE NOTICE 'PASS [1] Person A (chat_id) -> A''s Plan';

  -- TEST 2: chat_id 222 -> lena -> lenas Plan, nie erikas (Isolations-Leck zwischen Personen)
  SELECT plan_md INTO v_md FROM core.fn_advisor_read_plan('career','222');
  IF v_md IS DISTINCT FROM 'LENA PLAN MD' THEN RAISE EXCEPTION 'FAIL [2] chat_id 222 (lena) erwartet LENA, got % (ISOLATIONS-LECK: B sieht A!)', v_md; END IF;
  -- haerter: lena darf erikas Plan unter keinen Umstaenden im Result haben
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career','222') WHERE plan_md = 'ERIKA PLAN MD';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [2b] lena-Read enthaelt erikas Plan (Leck)'; END IF;
  RAISE NOTICE 'PASS [2] Person B -> B''s Plan, NIE A''s (Isolation)';

  -- TEST 3: kein chat_id -> leere Menge (fail-closed; ein Owner-Fallback waere ein Leck an jeden Frei-SQL-Aufrufer)
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career', NULL);
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [3] NULL chat_id erwartet leere Menge, got % Zeile(n)', v_cnt; END IF;
  RAISE NOTICE 'PASS [3] kein chat_id -> leere Menge (fail-closed)';

  -- TEST 4: nicht-numerischer / unaufgeloester chat_id -> leere Menge (kein RAISE, kein Cast auf bigint)
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career', 'notanumber');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [4a] nicht-numerischer chat_id erwartet leere Menge, got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career', '999');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [4b] unaufgeloester chat_id erwartet leere Menge, got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [4] nicht-numerischer/unaufgeloester chat_id -> leere Menge (kein RAISE)';

  -- TEST 6: core_ro liest advisor_plans gar nicht (Erlaubnisliste util_create_core_ro); die RLS bleibt zweiter Riegel
  -- und wird mit einem testlokalen Grant (ROLLBACK am Ende) weiter geprueft.
  BEGIN
    SET LOCAL ROLE core_ro;
    PERFORM 1 FROM agent.advisor_plans LIMIT 1;
    RESET ROLE;
    RAISE EXCEPTION 'FAIL [6] core_ro liest agent.advisor_plans (nicht auf der Erlaubnisliste)';
  EXCEPTION WHEN insufficient_privilege THEN RESET ROLE;
  END;
  GRANT SELECT ON agent.advisor_plans TO core_ro;
  SET LOCAL ROLE core_ro;
  SELECT count(*) INTO v_cnt FROM agent.advisor_plans WHERE domain = 'career';
  RESET ROLE;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [6a] core_ro sieht % Personen-Plan(e)', v_cnt; END IF;
  SET LOCAL ROLE core_ro;
  SELECT count(*) INTO v_cnt FROM agent.advisor_plans WHERE domain = '__rp_household__';
  RESET ROLE;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [6b] core_ro sieht den Haushalts-Plan nicht (got %)', v_cnt; END IF;
  REVOKE SELECT ON agent.advisor_plans FROM core_ro;
  RAISE NOTICE 'PASS [6] core_ro ohne Lesezugriff; RLS (zweiter Riegel) laesst nur Haushalts-Plaene durch';
END $$;

-- TEST 5: Frei-SQL-Sitzung (Login-Rolle career_ro, wie postgres_select) -> leere Menge, auch mit "fremder" chat_id.
-- SET SESSION AUTHORIZATION aendert session_user (SET ROLE nicht) — genau das prueft core.fn_is_free_sql_session.
SET LOCAL SESSION AUTHORIZATION career_ro;
DO $$
DECLARE v_cnt int;
BEGIN
  SELECT count(*) INTO v_cnt FROM core.fn_advisor_read_plan('career', '111');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [5] Frei-SQL-Sitzung (career_ro) las einen Personen-Plan per chat_id (Spoof-Leck)'; END IF;
  RAISE NOTICE 'PASS [5] Frei-SQL-Sitzung -> per_user-Plan leer (chat_id nicht spoofbar)';
END $$;
RESET SESSION AUTHORIZATION;
ROLLBACK;
