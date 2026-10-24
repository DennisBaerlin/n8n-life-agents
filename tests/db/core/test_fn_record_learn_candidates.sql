-- tests/db/core/test_fn_record_learn_candidates.sql
-- agent.fn_record_learn_candidates(p jsonb) — atomar: je Roh-Kandidat (LLM liefert Rohwerte)
--   Denylist-Vorfilter (fact, abgeleitete Felder raus) · Allowlist (fact-Kontext / note-Knowledge) ·
--   NOOP-vs-stored (fact gegen metadata.facts, note gegen "## Gelernt"-Substring) ·
--   Dedup x3 (in-batch · vs pending · vs kuerzlich rejected) · slot_key/kind DB-abgeleitet ·
--   Cap LIMIT daily_cap des Kalendertags (Prio update>new) · ON CONFLICT DO NOTHING (Idempotenz) ·
--   Watermark-Vorschub (GREATEST) in derselben Tx. Self-seedend, BEGIN..ROLLBACK.
BEGIN;

-- ---- Fixtures: family-facts (NOOP-fact), financial_planning-Prosa mit "## Gelernt" (NOOP-note), config ----
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('family', 'test fixture', NULL, 'lazy', E'## Haushalt\nProsa.', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object(
          'persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-05-20'),
            jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','M','role','child','birth_date','2024-01-01')),
          '_meta', jsonb_build_object('last_confirmed_at','2026-06-26'))))
ON CONFLICT (name) DO UPDATE SET content = excluded.content, managed_by = excluded.managed_by, metadata = excluded.metadata;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('financial_planning', 'test fixture', 'finance_advisor', 'lazy',
        E'# Finanzplan\n\n## Gelernt\n- Bekannte Notiz die schon da ist (gelernt am 2026-01-01 aus Chat)\n',
        'agent', 'finance', '{}'::jsonb)
ON CONFLICT (name) DO UPDATE SET content = excluded.content, managed_by = excluded.managed_by, metadata = excluded.metadata;
-- Phase A: Notiz-Freigabe registry-getrieben (core.advisors.learn_notes + aktives Paket statt Literal-Liste).
INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
INSERT INTO core.advisors (domain, plan_context, review_fn, package, learn_notes)
VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'finance', TRUE)
ON CONFLICT (domain) DO UPDATE SET plan_context = excluded.plan_context, learn_notes = TRUE;

INSERT INTO core.config (category, key, value, description, package) VALUES
  ('learn_context', 'daily_cap',   '10', 'test', 'core'),
  ('learn_context', 'expiry_days', '7',  'test', 'core')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value, package = excluded.package;

DO $$
DECLARE
  v_res   jsonb;
  v_n     int;
BEGIN
  -- ================= S1: Denylist + Allowlist + NOOP(fact+note) + happy (cap hoch) =================
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    -- c1 NOOP fact (erika.birth_date == gespeichert)
    jsonb_build_object('agent_name','finance','source_id',1,'target_kind','fact','context_name','family','person_slug','erika','field','birth_date','value','1980-05-20'),
    -- c2 update fact (lisa.last_name 'M' -> 'Mustermann') -> akzeptiert
    jsonb_build_object('agent_name','finance','source_id',2,'target_kind','fact','context_name','family','person_slug','lisa','field','last_name','value','Mustermann'),
    -- c3 DENYLIST (Feld 'age' = abgeleitet)
    jsonb_build_object('agent_name','finance','source_id',3,'target_kind','fact','context_name','family','person_slug','lisa','field','age','value','1'),
    -- c4 note neu (nicht im content) -> akzeptiert
    jsonb_build_object('agent_name','finance_advisor','source_id',4,'target_kind','note','context_name','financial_planning','value','plant 2027 ein Sabbatical'),
    -- c5 ALLOWLIST (note auf nicht-Knowledge-Kontext)
    jsonb_build_object('agent_name','finance_advisor','source_id',5,'target_kind','note','context_name','monitor_agent_instructions','value','soll nicht gelernt werden'),
    -- c6 NOOP note (schon in "## Gelernt")
    jsonb_build_object('agent_name','finance_advisor','source_id',6,'target_kind','note','context_name','financial_planning','value','Bekannte Notiz die schon da ist')
  )));

  IF (v_res->>'new_pending')::int <> 2 THEN RAISE EXCEPTION 'FAIL S1 [new_pending]: erwartet 2, got %', v_res; END IF;
  IF (v_res->'skipped'->>'noop')::int <> 2 THEN RAISE EXCEPTION 'FAIL S1 [noop]: erwartet 2, got %', v_res->'skipped'; END IF;
  IF (v_res->'skipped'->>'denylist')::int <> 1 THEN RAISE EXCEPTION 'FAIL S1 [denylist]: erwartet 1, got %', v_res->'skipped'; END IF;
  IF (v_res->'skipped'->>'allowlist')::int <> 1 THEN RAISE EXCEPTION 'FAIL S1 [allowlist]: erwartet 1, got %', v_res->'skipped'; END IF;
  -- inserted: 1 fact/update (last_name) + 1 note/new (financial_planning)
  SELECT count(*) INTO v_n FROM agent.guide_learn_candidates WHERE status='pending' AND target_kind='fact' AND kind='update' AND field='last_name';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL S1 [fact update inserted]: %', v_n; END IF;
  SELECT count(*) INTO v_n FROM agent.guide_learn_candidates WHERE status='pending' AND target_kind='note' AND kind='new' AND context_name='financial_planning';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL S1 [note new inserted]: %', v_n; END IF;
  RAISE NOTICE 'PASS S1 [denylist+allowlist+noop(fact,note)+fact-update+note-new]';

  -- ================= S1b (Install-UX-Phase 6): Fakt auf einen Paket-Fakten-Kontext nur bei AKTIVEM Paket =========
  -- core.fn_facts_context_allowed ersetzt die feste Liste family/finance_profile: finance_profile ist zulaessig,
  -- solange finance registriert+aktiv ist (Validator-Registry-Zeile vorhanden), sonst zaehlt der Kandidat als allowlist.
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET package = EXCLUDED.package;
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    jsonb_build_object('agent_name','finance_advisor','source_id',101,'target_kind','fact','context_name','finance_profile','person_slug','erika','field','steuerklasse','value','4'))));
  IF (v_res->>'new_pending')::int <> 1 THEN RAISE EXCEPTION 'FAIL S1b [finance aktiv]: erwartet new_pending=1, got %', v_res; END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    jsonb_build_object('agent_name','finance_advisor','source_id',102,'target_kind','fact','context_name','finance_profile','person_slug','erika','field','vorsorgesystem','value','grv'))));
  IF (v_res->'skipped'->>'allowlist')::int <> 1 OR (v_res->>'new_pending')::int <> 0 THEN
    RAISE EXCEPTION 'FAIL S1b [finance inaktiv]: erwartet allowlist=1/new_pending=0, got %', v_res;
  END IF;
  RAISE NOTICE 'PASS S1b [Fakt auf finance_profile nur bei aktivem finance-Paket]';

  -- ================= S2: Dedup vs pending + in-batch =================
  DELETE FROM agent.guide_learn_candidates;
  -- vorbestehender pending fuer slot family|lisa|last_name
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, expires_at)
  VALUES ('finance', 100, 'fact', 'family', 'lisa', 'last_name', 'Mustermann', 'update', 'family|lisa|last_name', now() + interval '7 days');
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    -- gleicher slot wie pending -> dedup
    jsonb_build_object('agent_name','finance','source_id',201,'target_kind','fact','context_name','family','person_slug','lisa','field','last_name','value','Neumann'),
    -- neuer slot family|erika|last_name -> akzeptiert (update; stored 'Mustermann' -> 'Andersson')
    jsonb_build_object('agent_name','finance','source_id',202,'target_kind','fact','context_name','family','person_slug','erika','field','last_name','value','Andersson'),
    -- gleicher slot wie 202 im selben Batch -> in-batch dedup
    jsonb_build_object('agent_name','finance','source_id',203,'target_kind','fact','context_name','family','person_slug','erika','field','last_name','value','Berg')
  )));
  IF (v_res->>'new_pending')::int <> 1 THEN RAISE EXCEPTION 'FAIL S2 [new_pending]: erwartet 1, got %', v_res; END IF;
  IF (v_res->'skipped'->>'dedup')::int <> 2 THEN RAISE EXCEPTION 'FAIL S2 [dedup]: erwartet 2, got %', v_res->'skipped'; END IF;
  RAISE NOTICE 'PASS S2 [dedup vs pending + in-batch]';

  -- ================= S3: Dedup vs kuerzlich rejected; alt-rejected NICHT mehr unterdrueckt =================
  DELETE FROM agent.guide_learn_candidates;
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, status, rejected_at, expires_at)
  VALUES
    ('finance', 300, 'fact', 'family', 'lisa', 'language',         'de',      'new', 'family|lisa|language',         'rejected', now(),                  now() + interval '7 days'),
    ('finance', 301, 'fact', 'family', 'lisa', 'education_status',  'student', 'new', 'family|lisa|education_status', 'rejected', now() - interval '30 days', now() - interval '23 days');
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    -- slot kuerzlich rejected -> dedup (Rejection-Memory)
    jsonb_build_object('agent_name','finance','source_id',310,'target_kind','fact','context_name','family','person_slug','lisa','field','language','value','en'),
    -- slot vor >expiry rejected -> wieder erlaubt
    jsonb_build_object('agent_name','finance','source_id',311,'target_kind','fact','context_name','family','person_slug','lisa','field','education_status','value','apprentice')
  )));
  IF (v_res->>'new_pending')::int <> 1 THEN RAISE EXCEPTION 'FAIL S3 [new_pending]: erwartet 1, got %', v_res; END IF;
  IF (v_res->'skipped'->>'dedup')::int <> 1 THEN RAISE EXCEPTION 'FAIL S3 [dedup]: erwartet 1, got %', v_res->'skipped'; END IF;
  RAISE NOTICE 'PASS S3 [dedup vs recent-rejected; old-rejected re-allowed]';

  -- ================= S4: Cap (daily_cap=2) + Prioritaet update>new =================
  DELETE FROM agent.guide_learn_candidates;
  UPDATE core.config SET value = '2' WHERE category='learn_context' AND key='daily_cap';
  v_res := agent.fn_record_learn_candidates(jsonb_build_object('candidates', jsonb_build_array(
    -- new1 (lisa.language nicht gespeichert -> new)
    jsonb_build_object('agent_name','finance','source_id',402,'target_kind','fact','context_name','family','person_slug','lisa','field','language','value','de'),
    -- new2 (lisa.citizenship nicht gespeichert -> new)
    jsonb_build_object('agent_name','finance','source_id',403,'target_kind','fact','context_name','family','person_slug','lisa','field','tax_residency','value','DE'),
    -- update1 (lisa.last_name 'M' -> 'Neu' = update) -> Prio
    jsonb_build_object('agent_name','finance','source_id',401,'target_kind','fact','context_name','family','person_slug','lisa','field','last_name','value','Neu')
  )));
  IF (v_res->>'new_pending')::int <> 2 THEN RAISE EXCEPTION 'FAIL S4 [new_pending]: erwartet 2, got %', v_res; END IF;
  IF (v_res->'skipped'->>'capped')::int <> 1 THEN RAISE EXCEPTION 'FAIL S4 [capped]: erwartet 1, got %', v_res->'skipped'; END IF;
  -- update1 MUSS dabei sein (Prio), genau eine der news faellt weg
  SELECT count(*) INTO v_n FROM agent.guide_learn_candidates WHERE status='pending' AND kind='update' AND field='last_name';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL S4 [update priorisiert]: %', v_n; END IF;
  SELECT count(*) INTO v_n FROM agent.guide_learn_candidates WHERE status='pending';
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL S4 [total pending]: %', v_n; END IF;
  RAISE NOTICE 'PASS S4 [cap haelt daily_cap; update priorisiert]';
  UPDATE core.config SET value = '10' WHERE category='learn_context' AND key='daily_cap';

  -- ================= S5: Idempotenz (ON CONFLICT) + Watermark (GREATEST) =================
  DELETE FROM agent.guide_learn_candidates;
  -- bereits APPROVED Kandidat (nicht im Dedup-Set: weder pending noch rejected) -> Insert-Versuch -> ON CONFLICT
  INSERT INTO agent.guide_learn_candidates (agent_name, source_id, target_kind, context_name, person_slug, field, proposed_value, kind, slot_key, status, approved_at, expires_at)
  VALUES ('finance', 500, 'fact', 'family', 'lisa', 'language', 'de', 'new', 'family|lisa|language', 'approved', now(), now() + interval '7 days');
  v_res := agent.fn_record_learn_candidates(jsonb_build_object(
    'candidates', jsonb_build_array(
      jsonb_build_object('agent_name','finance','source_id',500,'target_kind','fact','context_name','family','person_slug','lisa','field','language','value','de')),
    'watermarks', jsonb_build_array(jsonb_build_object('agent_name','finance','last_seen_id',60))));
  IF (v_res->>'new_pending')::int <> 0 THEN RAISE EXCEPTION 'FAIL S5 [idempotent new_pending]: erwartet 0, got %', v_res; END IF;
  IF (v_res->'skipped'->>'idempotent')::int <> 1 THEN RAISE EXCEPTION 'FAIL S5 [idempotent count]: %', v_res->'skipped'; END IF;
  SELECT last_seen_id INTO v_n FROM agent.guide_learn_watermark WHERE agent_name='finance';
  IF v_n <> 60 THEN RAISE EXCEPTION 'FAIL S5 [watermark set]: erwartet 60, got %', v_n; END IF;
  -- GREATEST: niedrigerer Wert darf nicht zurueckdrehen
  v_res := agent.fn_record_learn_candidates(jsonb_build_object(
    'watermarks', jsonb_build_array(jsonb_build_object('agent_name','finance','last_seen_id',55))));
  SELECT last_seen_id INTO v_n FROM agent.guide_learn_watermark WHERE agent_name='finance';
  IF v_n <> 60 THEN RAISE EXCEPTION 'FAIL S5 [watermark GREATEST]: erwartet 60, got %', v_n; END IF;
  RAISE NOTICE 'PASS S5 [idempotenz ON CONFLICT + watermark GREATEST]';

  RAISE NOTICE 'PASS fn_record_learn_candidates [all tests passed]';
END $$;

ROLLBACK;
