-- tests/db/career/test_fn_render_career_planning.sql
-- career.fn_render_career_planning: Header-only Render des career_planning-Sidecars, Ableitung
-- "angepeilter Umstieg ~Jahr" render-at-fetch. NULL wenn kein facts-Sidecar.
BEGIN;
DO $$
DECLARE v_hdr TEXT; v_year TEXT;
BEGIN
  IF career.fn_render_career_planning('career_planning') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [no row -> NULL]'; END IF;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_planning','t',NULL,'lazy','prose','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'target_roles', jsonb_build_array(
        jsonb_build_object('title','Scrum Master','salary_expectation_eur',75000),
        jsonb_build_object('title','Software-Entwickler')),
      'target_industries', jsonb_build_array('Tech','Finance'),
      'timeline_years', 2,
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE,'YYYY-MM-DD')))));

  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL THEN RAISE EXCEPTION 'FAIL [render NULL trotz facts]'; END IF;
  IF v_hdr NOT LIKE '%Scrum Master%' OR v_hdr NOT LIKE '%Tech%' OR v_hdr NOT LIKE '%2 Jahre%' THEN
    RAISE EXCEPTION 'FAIL [render content]: %', v_hdr;
  END IF;
  -- Ableitung: angepeilter Umstieg = heute + 2 Jahre (render-at-fetch, nie gespeichert)
  v_year := to_char(CURRENT_DATE + make_interval(years => 2), 'YYYY');
  IF v_hdr NOT LIKE '%angepeilter Umstieg ~' || v_year || '%' THEN
    RAISE EXCEPTION 'FAIL [derived target year %]: %', v_year, v_hdr;
  END IF;
  -- keine required_skills -> KEINE Skill-Luecken-Zeile
  IF v_hdr LIKE '%Skill-Lücken%' THEN RAISE EXCEPTION 'FAIL [no gap line ohne required_skills]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [1] no-row NULL + Header + render-at-fetch Umstiegs-Jahr + keine Gap-Zeile';

  -- ---------- TEST 2 (WS-3 Skill-Luecken-Zeile, primaere Rolle, Blocker zuerst) ----------
  -- Primaere Rolle Scrum Master bekommt required_skills; Profil hat Scrum nur beginner (weak+Pflicht), Python fehlt.
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_roles}', jsonb_build_array(
      jsonb_build_object('title','Scrum Master','required_skills', jsonb_build_array(
        jsonb_build_object('name','Scrum','min_level','advanced','is_blocker',true),
        jsonb_build_object('name','Python','min_level','intermediate'))),
      jsonb_build_object('title','Software-Entwickler')))
    WHERE name = 'career_planning';
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_profile','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object('skills', jsonb_build_array(
      jsonb_build_object('name','Scrum','level','beginner')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr NOT LIKE '%Skill-Lücken (Ziel Scrum Master)%' THEN RAISE EXCEPTION 'FAIL [2 gap line]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%[Pflicht]%' THEN RAISE EXCEPTION 'FAIL [2 blocker mark]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Scrum (beginner->advanced)%' THEN RAISE EXCEPTION 'FAIL [2 weak Ist->Soll]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Python%fehlt%' THEN RAISE EXCEPTION 'FAIL [2 missing]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [2] Skill-Lücken-Zeile (Blocker zuerst, weak Ist->Soll, missing)';

  -- ---------- TEST 3 (M1: kein career_profile -> kein Crash, alle missing) ----------
  DELETE FROM agent.core_contexts WHERE name = 'career_profile';
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Skill-Lücken (Ziel Scrum Master)%' THEN
    RAISE EXCEPTION 'FAIL [3 no-profile gap line]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [3] kein career_profile -> Lücken-Zeile (alle missing), kein Crash';

  -- ---------- TEST 4 (M1: Render unter dem Produktions-DEFINER-Pin) ----------
  -- core.fn_fetch_context pinnt search_path = pg_catalog, agent, core (KEIN career). Eine unqualifizierte
  -- career.*-Referenz im Renderer wuerde HIER failen (der Superuser-Default-Pfad oben maskiert das).
  SET LOCAL search_path = pg_catalog, agent, core;
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Skill-Lücken (Ziel Scrum Master)%' THEN
    RAISE EXCEPTION 'FAIL [4 render unter DEFINER-Pin]: %', v_hdr; END IF;
  RESET search_path;
  RAISE NOTICE 'PASS [4] Render unter Produktions-search_path-Pin (career.* schema-qualifiziert)';

  -- ---------- TEST 5 (WS-4 Markt-Zeile: Stellen-Nachfrage + Trend, render-at-fetch) ----------
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,target_locations}', jsonb_build_array('Hamburg'))
    WHERE name = 'career_planning';
  INSERT INTO career.market_signals (scope_key, as_of, postings_count)
    VALUES (career.fn_market_scope_key('postings','Scrum Master','Hamburg'), CURRENT_DATE - 7, 100);
  INSERT INTO career.market_signals (scope_key, as_of, postings_count)
    VALUES (career.fn_market_scope_key('postings','Scrum Master','Hamburg'), CURRENT_DATE, 120);
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr NOT LIKE '%Stellen-Nachfrage: 120 offene Stellen%' OR v_hdr NOT LIKE '%Trend +20%' THEN
    RAISE EXCEPTION 'FAIL [5 Stellen-Nachfrage+Trend]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [5] Markt-Zeile (Stellen-Nachfrage + Posting-Trend)';

  -- ---------- TEST 6 (Markt-Zeile unter dem Produktions-DEFINER-Pin — career.market_signals-Read) ----------
  -- Der NEUE Cross-Schema-Read (career.market_signals via fn_market_trend) muss unter dem fn_fetch_context-
  -- search_path (pg_catalog,agent,core; KEIN career) greifen -> alle career.*-Refs schema-qualifiziert.
  SET LOCAL search_path = pg_catalog, agent, core;
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Stellen-Nachfrage%' THEN
    RAISE EXCEPTION 'FAIL [6 Markt-Zeile unter DEFINER-Pin]: %', v_hdr; END IF;
  RESET search_path;
  RAISE NOTICE 'PASS [6] Markt-Zeile unter Produktions-search_path-Pin (career.market_signals schema-qualifiziert)';
END $$;

-- ============================================================
-- WS-5 — Runway-Zeile (Cross-Paket-Read finance->career, render-at-fetch, Doppel-Guard + graceful degradation).
--   Eigener DO-Block (das career_planning-Sidecar lebt aus Block 1 in derselben Transaktion weiter).
-- ============================================================
DO $$
DECLARE v_hdr text; v_cashacct int;
BEGIN
  -- finance aktiv + Cash/Ausgaben + transition-Szenario-Fakten
  INSERT INTO core.package_registry (package, status) VALUES ('finance','active')
    ON CONFLICT (package) DO UPDATE SET status='active';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rwr_cash__','cash','EUR','active') RETURNING id INTO v_cashacct;
  UPDATE finance.account_balances SET balance = 60000 WHERE account_id = v_cashacct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__rwr_exp__', v_cashacct, -5000, 'month', current_date, current_date);
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,transition}',
    jsonb_build_object('probation_months', 6, 'expected_gap_income_eur', 0)) WHERE name='career_planning';

  -- ---------- TEST 7: Runway-Zeile erscheint mit finance praesent + transition-Fakten ----------
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr NOT LIKE '%Runway:%' THEN RAISE EXCEPTION 'FAIL [7 Runway-Zeile fehlt]: %', v_hdr; END IF;
  RAISE NOTICE 'PASS [7] Runway-Zeile rendert (finance präsent)';

  -- ---------- TEST 8 (Opus m8): Runway-Read unter dem Produktions-DEFINER-Pin (finance.* schema-qualifiziert) ----------
  -- core.fn_fetch_context pinnt search_path = pg_catalog, agent, core (KEIN finance, KEIN career) -> jede
  -- finance.*-/career.*-Ref im Runway-Pfad muss schema-qualifiziert sein, sonst failt der Read HIER (der
  -- Superuser-Default-Pfad oben maskiert das). Hoechstes "was faende Schritt 8"-Risiko: Grant/search_path.
  SET LOCAL search_path = pg_catalog, agent, core;
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Runway:%' THEN
    RAISE EXCEPTION 'FAIL [8 Runway unter DEFINER-Pin]: %', v_hdr; END IF;
  RESET search_path;
  RAISE NOTICE 'PASS [8] Runway-Zeile unter Produktions-search_path-Pin (finance.* schema-qualifiziert)';

  -- ---------- TEST 8b (WP-3c): Fremdwaehrungs-Cash ohne Kurs -> Runway-Zeile traegt einen FX-Warnhinweis ----------
  IF v_hdr LIKE '%Fremdwährungs-Konto ohne aktuellen Wechselkurs%' THEN
    RAISE EXCEPTION 'FAIL [8b baseline]: FX-Warnhinweis obwohl (noch) kein Fremdwährungs-Konto'; END IF;
  DECLARE v_krw int; BEGIN
    INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__rwr_krw__','cash','KRW','active') RETURNING id INTO v_krw;
    UPDATE finance.account_balances SET balance = 1450000 WHERE account_id = v_krw;   -- KRW-Guthaben ohne fx_rate
    v_hdr := career.fn_render_career_planning('career_planning');
    IF v_hdr NOT LIKE '%Fremdwährungs-Konto ohne aktuellen Wechselkurs%' THEN
      RAISE EXCEPTION 'FAIL [8b warn]: Runway-Zeile ohne FX-Warnhinweis trotz kurslosem KRW-Konto: %', v_hdr; END IF;
    RAISE NOTICE 'PASS [8b] KRW-Cash ohne Kurs -> Runway-Zeile trägt sichtbaren FX-Warnhinweis (nie still unterzählen)';
  END;

  -- ---------- TEST 9 (graceful degradation): finance inaktiv -> Runway-Zeile entfaellt, Plan rendert weiter ----------
  UPDATE core.package_registry SET status='inactive' WHERE package='finance';
  v_hdr := career.fn_render_career_planning('career_planning');
  IF v_hdr IS NULL THEN RAISE EXCEPTION 'FAIL [9 render NULL bei inaktivem finance]'; END IF;
  IF v_hdr LIKE '%Runway:%' THEN RAISE EXCEPTION 'FAIL [9 Runway-Zeile trotz inaktivem finance]: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Ziel-Rolle%' THEN RAISE EXCEPTION 'FAIL [9 Rest-Render fehlt]: %', v_hdr; END IF;
  UPDATE core.package_registry SET status='active' WHERE package='finance';
  RAISE NOTICE 'PASS [9] finance inaktiv -> Runway-Zeile entfällt graceful, Plan rendert weiter';
END $$;

-- ============================================================
-- TEST 10 (P0c per-Person): career_planning ist per_user -> p_name ist der PHYSISCHE, suffigierte Name
--   (career_planning__<pid>). Der Renderer leitet die person_id aus p_name ab und liest career_profile__<pid>
--   (KEIN Suspend-Guard mehr) -> die Skill-Luecken-Zeile rendert WIEDER, pro Person.
-- ============================================================
DO $$
DECLARE v_hdr text;
BEGIN
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES
    ('career_profile','per_user','own_user_only','career'),
    ('career_planning','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user';
  -- Suffix-Contexts: Plan (Scrum Master required_skills) + Profil OHNE die Skills -> echte Luecke.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('career_planning__erika','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object(
      'target_roles', jsonb_build_array(jsonb_build_object('title','Scrum Master','required_skills',
        jsonb_build_array(jsonb_build_object('name','Scrum','min_level','advanced','is_blocker',true)))),
      'timeline_years', 2,
      '_meta', jsonb_build_object('last_confirmed_at', to_char(CURRENT_DATE,'YYYY-MM-DD'))))),
   ('career_profile__erika','t',NULL,'lazy','p','agent','career',
    jsonb_build_object('facts', jsonb_build_object('skills','[]'::jsonb)))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  v_hdr := career.fn_render_career_planning('career_planning__erika');
  IF v_hdr IS NULL OR v_hdr NOT LIKE '%Ziel-Rolle%' THEN
    RAISE EXCEPTION 'FAIL [10 per-Person]: Plan rendert nicht: %', v_hdr; END IF;
  IF v_hdr NOT LIKE '%Skill-Lücken (Ziel Scrum Master)%' THEN
    RAISE EXCEPTION 'FAIL [10 per-Person]: Skill-Lücken-Zeile fehlt (Suffix-Read career_profile__pid greift nicht): %', v_hdr; END IF;
  RAISE NOTICE 'PASS [10] P0c per-Person [Renderer leitet pid aus p_name ab -> career_profile__pid -> Gap-Zeile rendert]';
END $$;
ROLLBACK;
