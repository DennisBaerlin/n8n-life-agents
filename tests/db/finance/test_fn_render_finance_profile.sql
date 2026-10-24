-- tests/db/finance/test_fn_render_finance_profile.sql
-- Testet den paket-besessenen Finanzprofil-Renderer finance.fn_render_finance_profile(text) (Phase A: aus dem
-- Core [vormals agent.fn_finance_profile_context] ins finance-Paket gezogen) ueber die generische Engine
-- core.fn_fetch_context: joint BEIDE Sidecars (Wunsch-Rentenjahr aus family.birth_date + fp.planned_retirement_age),
-- Header-only (Banner/Stempel/'---'/Prosa setzt die Engine), leere persons -> Fallback-Zeile statt Junk-Bullet.
-- db_test seedet core.context_renderers NICHT -> der Test seedet die Registry-Zeile selbst, wie seed_data.sh
-- sie aus packages/finance/manifest.json "context_renderers" setzt.
BEGIN;

DO $$
DECLARE
  v_txt TEXT;
BEGIN
  -- REIHENFOLGE: erst finance_profile-Personen leeren (sonst blockt die Waisen-Pruefung den family-Fixture-Write),
  -- dann family, dann finance_profile darauf.
  UPDATE agent.core_contexts
  SET metadata = jsonb_set(COALESCE(metadata,'{}'::jsonb), '{facts,persons}', '[]'::jsonb)
  WHERE name = 'finance_profile';

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa-Body',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('finance_profile', 'test fixture', 'finance_advisor', 'lazy', E'## FP-Prosa', 'agent', 'finance',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','planned_retirement_age',63,'vorsorgesystem','grv')))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO core.context_renderers (context_name, render_fn, package)
  VALUES ('finance_profile', 'finance.fn_render_finance_profile', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET render_fn = EXCLUDED.render_fn, package = EXCLUDED.package;

  -- ---------- TEST 1 (BIT-REGRESSION): finance_profile ueber die Engine joint beide Sidecars ----------
  SELECT content INTO v_txt FROM core.fn_fetch_context('finance_profile');
  IF v_txt NOT LIKE '%Authoritative facts%' THEN
    RAISE EXCEPTION 'FAIL finance_profile [engine banner]: Banner fehlt: %', left(v_txt, 200);
  END IF;
  -- Wunsch-Rentenjahr = Geburtsjahr 1980 + 63 = 2043 (Join family.birth_date x fp.planned_retirement_age)
  IF v_txt NOT LIKE '%2043%' OR v_txt NOT LIKE '%Erika Mustermann%' THEN
    RAISE EXCEPTION 'FAIL finance_profile [header]: Name/Wunsch-Rentenjahr 2043 fehlt: %', left(v_txt, 400);
  END IF;
  IF v_txt NOT LIKE '%FP-Prosa%' THEN
    RAISE EXCEPTION 'FAIL finance_profile [engine wrap]: Prosa-Body fehlt';
  END IF;
  RAISE NOTICE 'PASS finance.fn_render_finance_profile [Engine: Join beider Sidecars 1980+63=2043 + Prosa]';

  -- ---------- TEST 2 (Review A3): leeres persons-Array -> KEIN Junk-Bullet, Fallback-Text ----------
  UPDATE agent.core_contexts
  SET metadata = jsonb_set(metadata, '{facts,persons}', '[]'::jsonb)
  WHERE name = 'finance_profile';
  SELECT content INTO v_txt FROM core.fn_fetch_context('finance_profile');
  IF v_txt LIKE '%' || E'\n- \n' || '%' OR v_txt NOT LIKE '%no person-level finance facts%' OR v_txt NOT LIKE '%FP-Prosa%' THEN
    RAISE EXCEPTION 'FAIL finance_profile [empty persons]: Junk-Bullet/fehlender Fallback/Prosa: %', left(v_txt, 300);
  END IF;
  RAISE NOTICE 'PASS finance.fn_render_finance_profile [leere persons -> Fallback-Zeile statt Junk-Bullet]';

  -- ---------- TEST 3: die alte Core-fn existiert nicht mehr (core:V019) ----------
  IF to_regprocedure('agent.fn_finance_profile_context(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [retired]: agent.fn_finance_profile_context existiert noch';
  END IF;
  RAISE NOTICE 'PASS [alter Core-Renderer entfernt]';
END $$;

ROLLBACK;
