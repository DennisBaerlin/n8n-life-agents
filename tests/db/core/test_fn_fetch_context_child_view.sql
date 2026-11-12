-- tests/db/core/test_fn_fetch_context_child_view.sql
-- core.fn_fetch_context(name, chat_id) mit Kinder-Sicht (core.fn_sender_sees_household):
--   Kind: Paket-Kontext (auch ohne context_scopes-Zeile) -> Hinweiszeile; restaurierter Plan-Kontext mit package 'core'
--   -> ebenfalls Hinweis (Paket aus core.advisors/context_renderers abgeleitet); eigener per_user-Kontext -> Inhalt;
--   family -> nur Vornamen + Rollen; Core-Kontext -> Inhalt. Erwachsener und Systempfad (chat_id NULL) -> voller Inhalt.
--   Unbekannte numerische chat_id -> wie ein Kind.
BEGIN;
DO $$
DECLARE
  v text;
  c_hint constant text := 'This document is only available to the adults of the household. Do not guess its content.';
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 't', NULL, 'lazy', 'FAMILY-PROSE', jsonb_build_object('facts', jsonb_build_object(
    'household', jsonb_build_object('joint_finances', true),
    'persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'employment','Angestellte'),
      jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','M','role','child','birth_date','2014-03-02','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, content = EXCLUDED.content;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata, package)
  VALUES ('__cv_fin__', 'fix', NULL, 'lazy', 'FIN-PLAN', '{}'::jsonb, 'finance'),
         ('__cv_core__', 'fix', NULL, 'lazy', 'CORE-DOC', '{}'::jsonb, 'core'),
         ('__cv_restored__', 'fix', NULL, 'lazy', 'RESTORED-PLAN', '{}'::jsonb, 'core'),
         ('__cv_own__', 'fix', NULL, 'lazy', 'BASE', '{}'::jsonb, 'career'),
         ('__cv_own____lisa', 'fix', NULL, 'lazy', 'LISA-OWN', '{}'::jsonb, 'career')
  ON CONFLICT (name) DO UPDATE SET content = EXCLUDED.content, package = EXCLUDED.package, load_strategy = 'lazy';
  DELETE FROM core.context_scopes WHERE context_name IN ('__cv_fin__', '__cv_own__');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES ('__cv_own__', 'per_user', 'own_user_only', 'career');
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step)
  VALUES ('__cv_dom__', '__cv_restored__', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', false)
  ON CONFLICT (domain) DO UPDATE SET plan_context = EXCLUDED.plan_context;

  -- Kind
  SELECT content INTO v FROM core.fn_fetch_context('__cv_fin__', '333');
  IF v IS DISTINCT FROM c_hint THEN RAISE EXCEPTION 'FAIL [1 Kind Paket-Kontext ohne Scope-Zeile]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('__cv_restored__', '333');
  IF v IS DISTINCT FROM c_hint THEN RAISE EXCEPTION 'FAIL [2 Kind restaurierter Plan-Kontext]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('__cv_own__', '333');
  IF v IS DISTINCT FROM 'LISA-OWN' THEN RAISE EXCEPTION 'FAIL [3 Kind eigener per_user-Kontext]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('__cv_core__', '333');
  IF v IS DISTINCT FROM 'CORE-DOC' THEN RAISE EXCEPTION 'FAIL [4 Kind Core-Kontext]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('family', '333');
  IF v NOT LIKE 'Household members (first name, role): Erika (owner), Lisa (child).%' OR v LIKE '%Angestellte%'
     OR v LIKE '%joint_finances%' OR v LIKE '%FAMILY-PROSE%' THEN RAISE EXCEPTION 'FAIL [5 Kind family schmal]: %', v; END IF;
  -- unbekannt wie Kind
  SELECT content INTO v FROM core.fn_fetch_context('__cv_fin__', '999');
  IF v IS DISTINCT FROM c_hint THEN RAISE EXCEPTION 'FAIL [6 unbekannt]: %', v; END IF;
  -- Erwachsener, Systempfad, Test-Sentinel
  SELECT content INTO v FROM core.fn_fetch_context('__cv_fin__', '111');
  IF v IS DISTINCT FROM 'FIN-PLAN' THEN RAISE EXCEPTION 'FAIL [7 Owner]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('family', '111');
  IF v NOT LIKE '%FAMILY-PROSE%' THEN RAISE EXCEPTION 'FAIL [8 Owner family voll]: %', left(v, 120); END IF;
  SELECT content INTO v FROM core.fn_fetch_context('__cv_restored__', NULL);
  IF v IS DISTINCT FROM 'RESTORED-PLAN' THEN RAISE EXCEPTION 'FAIL [9 Systempfad]: %', v; END IF;
  SELECT content INTO v FROM core.fn_fetch_context('__cv_fin__', 'test_cv');
  IF v IS DISTINCT FROM 'FIN-PLAN' THEN RAISE EXCEPTION 'FAIL [10 Test-Sentinel]: %', v; END IF;

  RAISE NOTICE 'PASS test_fn_fetch_context_child_view';
END $$;
ROLLBACK;
