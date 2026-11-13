-- tests/db/core/test_fn_advisor_save_section.sql
-- Testet fn_advisor_save_section: Draft-Anlage + Sektions-Upsert in interview_state.
-- Vertrag: {ok:true, plan_id, version, status, sections, section_count} |
--          korrigierbar (leerer section_key/content, invalides section_data-JSON) -> {ok:false, reason}.
-- Invarianten (DB-Gesetz): genau ein draft pro domain (Partial-UNIQUE), UNIQUE(domain, version).
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_plan_id  INT;
  v_state    JSONB;
  v_count    INT;
BEGIN

  -- TEST 1: erster Save ohne existierenden Draft -> Draft wird angelegt (version 1, status draft)
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain',          '__test_domain__',
    'plan_name',       '__test_plan__',
    'section_key',     'household_basics',
    'section_content', 'Net income 5000 EUR/month, two adults, one child.'
  )) INTO v_result;

  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [first save]: erwartet ok=true, got %', v_result;
  END IF;
  v_plan_id := (v_result->>'plan_id')::int;
  IF (v_result->>'version')::int IS DISTINCT FROM 1 OR (v_result->>'status') IS DISTINCT FROM 'draft' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [first save]: erwartet version=1/status=draft, got %', v_result;
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM agent.advisor_plans
    WHERE id = v_plan_id AND domain = '__test_domain__' AND status = 'draft'
      AND plan_name = '__test_plan__' AND version = 1
  ) THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section: Draft-Zeile nicht korrekt in DB';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [Draft angelegt, plan_id=%]', v_plan_id;

  -- Assert: Sektion liegt in interview_state unter dem section_key
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_plan_id;
  IF v_state->'household_basics'->>'content' IS DISTINCT FROM 'Net income 5000 EUR/month, two adults, one child.' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [interview_state]: Sektion fehlt/falsch, got %', v_state;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [Sektion in interview_state]';

  -- TEST 2: zweite Sektion -> beide Keys vorhanden, derselbe Draft (kein zweiter)
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain',          '__test_domain__',
    'section_key',     'risk_protection',
    'section_content', 'Liability insurance present, no disability insurance.'
  )) INTO v_result;
  IF (v_result->>'plan_id')::int IS DISTINCT FROM v_plan_id THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [second section]: neuer Draft statt Upsert, got %', v_result;
  END IF;
  IF (v_result->>'section_count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [second section]: erwartet section_count=2, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [zweite Sektion, section_count=2]';

  -- TEST 2b: reine Textsektion: leeres section_data (das Tool-Binding liefert beim Weglassen '') zaehlt als nicht angegeben
  -- (sonst kaeme die Ablehnung erst nach der bestaetigten Karte).
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_domain__', 'section_key', 'prose_empty',
    'section_content', 'Nur Text.', 'section_data', ''
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [section_data leer]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_domain__', 'section_key', 'prose_blank',
    'section_content', 'Nur Text.', 'section_data', '   '
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [section_data Leerzeichen]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_plan_id;
  IF v_state->'prose_empty' ? 'data' OR v_state->'prose_blank' ? 'data' OR v_state->'prose_empty'->>'content' IS DISTINCT FROM 'Nur Text.' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [section_data leer]: Sektion falsch, got %', v_state;
  END IF;
  UPDATE agent.advisor_plans SET interview_state = interview_state - 'prose_empty' - 'prose_blank' WHERE id = v_plan_id;
  RAISE NOTICE 'PASS fn_advisor_save_section [leeres section_data = nicht angegeben]';

  -- TEST 3: Upsert derselben Sektion -> Inhalt ersetzt, weiterhin 2 Sektionen
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain',          '__test_domain__',
    'section_key',     'risk_protection',
    'section_content', 'CORRECTED: disability insurance now covered via employer.'
  )) INTO v_result;
  IF (v_result->>'section_count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [upsert]: erwartet section_count=2, got %', v_result;
  END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_plan_id;
  IF v_state->'risk_protection'->>'content' NOT LIKE 'CORRECTED:%' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [upsert]: Inhalt nicht ersetzt, got %', v_state->'risk_protection';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [Upsert ersetzt Inhalt]';

  -- TEST 4: strukturiertes section_data als JSON-String -> geparst gespeichert
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain',          '__test_domain__',
    'section_key',     'goals',
    'section_content', 'Buy apartment 2030, retire 2055.',
    'section_data',    '{"target_year": 2030, "amount": 100000}'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [section_data string]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_plan_id;
  IF (v_state->'goals'->'data'->>'target_year')::int IS DISTINCT FROM 2030 THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [section_data]: nicht geparst gespeichert, got %', v_state->'goals';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [section_data JSON-String geparst]';

  -- TEST 5: invalides section_data-JSON -> {ok:false}, kein Write (korrigierbare Ablehnung)
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain',          '__test_domain__',
    'section_key',     'broken',
    'section_content', 'whatever',
    'section_data',    '{not valid json'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [invalid json]: erwartet ok=false, got %', v_result;
  END IF;
  SELECT interview_state INTO v_state FROM agent.advisor_plans WHERE id = v_plan_id;
  IF v_state ? 'broken' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [invalid json]: Sektion wurde trotzdem geschrieben';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [invalides JSON -> ok:false, kein Write]';

  -- TEST 6: leerer section_key -> {ok:false}
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_domain__', 'section_key', '  ', 'section_content', 'x'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [empty key]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [leerer section_key -> ok:false]';

  -- TEST 7: leerer section_content -> {ok:false}
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_domain__', 'section_key', 'goals', 'section_content', ''
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [empty content]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [leerer section_content -> ok:false]';

  -- TEST 8: domain ist Pflicht — kein domain im Payload -> {ok:false}, kein Draft (ein stiller Default
  -- 'finance' waere falsch; Core kennt kein Paket)
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'plan_name', '__test_default_domain__', 'section_key', 's1', 'section_content', 'x'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%domain is required%' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [domain required]: erwartet ok=false, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.advisor_plans WHERE plan_name = '__test_default_domain__') THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [domain required]: trotzdem ein Draft angelegt';
  END IF;
  IF (agent.fn_advisor_publish_plan(jsonb_build_object('plan_md', '# x'))->>'reason') NOT ILIKE '%domain is required%' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_publish_plan [domain required]';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section/publish_plan [domain Pflicht -> ok:false ohne Write]';

  -- TEST 8b (owner_only-Backstop): gepairter Nicht-Owner darf keine Plaene schreiben.
  -- family-Fixture (erika owner@111, lena partner@222). chat_id=222 -> {ok:false, owner_only}, kein Draft.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'save_section owner-check fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','protected', true,
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')
            ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  SELECT count(*)::int INTO v_count FROM agent.advisor_plans WHERE domain = '__owner_only_dom__';
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain','__owner_only_dom__', 'chat_id','222',
    'section_key','x', 'section_content','member tries to write a plan'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [non-owner]: erwartet ok=false/owner_only, got %', v_result;
  END IF;
  IF (SELECT count(*)::int FROM agent.advisor_plans WHERE domain = '__owner_only_dom__') <> v_count THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [non-owner]: Draft wurde trotzdem angelegt';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [gepairter Nicht-Owner -> owner_only, kein Write]';

  -- Owner (erika@111) darf -> ok (Kontrolle); nicht-numerischer Sentinel -> ok (durchlassen)
  IF (agent.fn_advisor_save_section(jsonb_build_object(
        'domain','__owner_only_dom__','chat_id','111','section_key','x','section_content','owner writes'))->>'ok')::boolean
     IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [owner allowed]: erwartet ok=true';
  END IF;
  IF (agent.fn_advisor_save_section(jsonb_build_object(
        'domain','__owner_only_dom2__','chat_id','test_e2e_ae01','section_key','x','section_content','sentinel'))->>'ok')::boolean
     IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_advisor_save_section [sentinel pass-through]: erwartet ok=true';
  END IF;
  RAISE NOTICE 'PASS fn_advisor_save_section [Owner + Sentinel durchlassen]';

  -- TEST 9 (Invariante, DB-Gesetz): zweiter Draft fuer dieselbe domain per Direkt-INSERT -> unique_violation
  BEGIN
    INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
    VALUES ('__test_domain__', '__test_second_draft__', 'draft', 99);
    RAISE EXCEPTION 'FAIL advisor_plans [one-draft-per-domain]: zweiter Draft wurde akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS advisor_plans [Partial-UNIQUE: ein Draft pro Domain]';
  END;

  -- TEST 10 (Invariante): doppelte (domain, version) per Direkt-INSERT -> unique_violation
  BEGIN
    INSERT INTO agent.advisor_plans (domain, plan_name, status, version)
    VALUES ('__test_domain__', '__test_dup_version__', 'superseded', 1);
    RAISE EXCEPTION 'FAIL advisor_plans [unique domain+version]: Duplikat wurde akzeptiert';
  EXCEPTION WHEN unique_violation THEN
    RAISE NOTICE 'PASS advisor_plans [UNIQUE(domain, version)]';
  END;

END $$;

-- TEST 11: as_of stempelt die fn, relative Daten rechnet die DB
DO $$
DECLARE
  v_result JSONB;
  v_state  JSONB;
BEGIN
  SELECT agent.fn_advisor_save_section(jsonb_build_object(
    'domain', '__test_domain_asof__', 'section_key', 'risk', 'section_content', 'Risk profile confirmed.',
    'section_data', jsonb_build_object(
      'risk_profile', jsonb_build_object('risk_tolerance', 'medium', 'as_of', '2001-01-01'),
      'goal', jsonb_build_object('target_portfolio_basis', 'investment'),
      'target_date', '+2 years',
      'target_roles', jsonb_build_array(jsonb_build_object('title', 'Data Analyst'))))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL save_section as_of: erwartet ok, got %', v_result; END IF;
  SELECT interview_state->'risk'->'data' INTO v_state FROM agent.advisor_plans
   WHERE domain = '__test_domain_asof__' AND status = 'draft';
  IF (v_state->'risk_profile'->>'as_of')::date IS DISTINCT FROM CURRENT_DATE
     OR (v_state->'goal'->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL save_section as_of: jeder Objekt-Block traegt heute (LLM-Wert ueberschrieben), got %', v_state; END IF;
  IF v_state ? 'as_of' OR v_state->'target_roles'->0 ? 'as_of' THEN
    RAISE EXCEPTION 'FAIL save_section as_of: nur Top-Level-Objekte, keine Skalare/Arrays, got %', v_state; END IF;
  IF v_state->>'target_date' IS DISTINCT FROM to_char(CURRENT_DATE + interval '2 years', 'YYYY') THEN
    RAISE EXCEPTION 'FAIL save_section relative Daten: "+2 years" -> Jahr erwartet, got %', v_state->>'target_date'; END IF;
  RAISE NOTICE 'PASS save_section [as_of je Objekt-Block von der fn, LLM-Wert ueberschrieben, +2 years -> YYYY]';
END $$;

-- TEST 12: unbekannter section_key -> {ok:false, code, valid_keys} ohne Write, sobald der Textkatalog des
-- Pakets Abschnitts-Keys fuehrt; ohne Katalog-Keys (Test-DB, Paket ohne Plan) bleibt der Key frei.
DO $$
DECLARE
  v_result JSONB;
  v_n      INT;
BEGIN
  DELETE FROM core.advisors WHERE domain IN ('__ssk_dom__', '__ssk_free__');
  INSERT INTO core.advisors (domain, plan_context, review_fn, package) VALUES
    ('__ssk_dom__',  '__ssk_dom___planning',  'finance.fn_advisor_review', 'ssk'),
    ('__ssk_free__', '__ssk_free___planning', 'finance.fn_advisor_review', 'sskfree');
  INSERT INTO core.ui_texts (key, lang, text, package) VALUES
    ('ssk.plan_section.risk_profile', 'en', 'Risk profile', 'ssk'),
    ('ssk.plan_section.goals',        'en', 'Goals',        'ssk'),
    ('ssk.plan_section.phase2',       'en', 'Phase 2',      'ssk'),
    ('ssk.plan_section.goals.hint',   'en', 'not a section', 'ssk')
  ON CONFLICT (key, lang) DO UPDATE SET text = EXCLUDED.text;

  -- Tippfehler -> abgelehnt, mit den gueltigen Keys (Unter-Key ist kein Abschnitt), kein Draft
  v_result := agent.fn_advisor_save_section(jsonb_build_object('domain', '__ssk_dom__', 'plan_name', '__ssk_plan__',
      'section_key', 'risk_profil', 'section_content', 'Mittlere Risikobereitschaft.'));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'code' IS DISTINCT FROM 'unknown_section_key'
     OR v_result->'valid_keys' IS DISTINCT FROM '["goals","phase2","risk_profile"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL save_section [S2.11 Tippfehler]: erwartet ok:false/unknown_section_key/valid_keys goals+phase2+risk_profile, got %', v_result;
  END IF;
  SELECT count(*) INTO v_n FROM agent.advisor_plans WHERE domain = '__ssk_dom__';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL save_section [S2.11]: abgelehnter Key hat einen Draft angelegt'; END IF;

  v_result := agent.fn_advisor_save_section(jsonb_build_object('domain', '__ssk_dom__', 'section_key', 'goals.hint',
      'section_content', 'x'));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL save_section [S2.11 Unter-Key]: erwartet ok:false, got %', v_result; END IF;

  -- E2E-Domain erbt die Regel der echten Domain
  v_result := agent.fn_advisor_save_section(jsonb_build_object('domain', '__e2e___ssk_dom____', 'section_key', 'risk_profil',
      'section_content', 'x'));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'code' IS DISTINCT FROM 'unknown_section_key' THEN
    RAISE EXCEPTION 'FAIL save_section [S2.11 E2E-Domain]: erwartet unknown_section_key, got %', v_result; END IF;

  -- gueltiger Key -> gespeichert
  v_result := agent.fn_advisor_save_section(jsonb_build_object('domain', '__ssk_dom__', 'section_key', 'risk_profile',
      'section_content', 'Mittlere Risikobereitschaft.'));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL save_section [S2.11 gueltig]: erwartet ok, got %', v_result; END IF;

  -- Paket ohne Katalog-Keys: Key bleibt frei
  v_result := agent.fn_advisor_save_section(jsonb_build_object('domain', '__ssk_free__', 'section_key', 'anything_goes',
      'section_content', 'x'));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL save_section [S2.11 frei]: Paket ohne plan_section-Keys darf jeden Key, got %', v_result; END IF;
  RAISE NOTICE 'PASS save_section [S2.11 unbekannter section_key abgelehnt, gueltig/frei erlaubt]';
END $$;

ROLLBACK;
