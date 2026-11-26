-- tests/db/core/test_fn_advisor_pins.sql
-- core.fn_advisor_pins(p): die eine Adresse fuer "wer hat einen offenen Entwurf" (Router-Flags interview_advisor und
-- paused_advisor). Je Zeile der Matrix ein Fall:
--   heiss (< 2 h) -> nur interview_advisor; 3 Tage -> nur paused_advisor; aelter als advisor.rollout_draft_stale_days
--   -> beide leer; Entwurf eines anderen Mitglieds / Haushalts-Entwurf fuer ein Mitglied -> leer; eigener Entwurf eines
--   Mitglieds -> seiner; zwei Entwuerfe -> der juengste; Paket inaktiv -> leer; leere Eingabe -> leer; genau zwei Keys.
--   Rechte (core_ro ja, Paket-Rolle nein): tests/db/cross/test_role_permissions.sql (3e-PINS).
-- db_test hat kein seed_data -> Registry, Berater, Plaene self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v jsonb;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true);
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'rollout_draft_stale_days';
  -- trg_advisor_plans_touch stempelt updated_at selbst -> fuer die Alters-Faelle in dieser Transaktion aus
  ALTER TABLE agent.advisor_plans DISABLE TRIGGER trg_advisor_plans_touch;

  -- ---------- (1) Haushalts-Entwurf heiss (< 2 h), Owner -> nur interview_advisor; genau zwei Keys ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('finance', NULL, 'Plan', 'draft', 1, '{}', now() - interval '30 minutes');
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'interview_advisor' IS DISTINCT FROM 'agent.finance_advisor' OR v->>'paused_advisor' IS NOT NULL
     OR (SELECT count(*) FROM jsonb_object_keys(v)) <> 3 OR NOT (v ? 'paused_advisor') OR NOT (v ? 'open_prompt_agent') THEN
    RAISE EXCEPTION 'FAIL [1 heiss]: %', v; END IF;

  -- ---------- (2) 3 Tage alt -> nur paused_advisor ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '3 days' WHERE domain = 'finance';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'interview_advisor' IS NOT NULL OR v->>'paused_advisor' IS DISTINCT FROM 'agent.finance_advisor' THEN
    RAISE EXCEPTION 'FAIL [2 pausiert]: %', v; END IF;
  -- Grenze 2 h: genau an der Grenze schon pausiert (heiss heisst juenger als 2 h)
  UPDATE agent.advisor_plans SET updated_at = now() - interval '2 hours' WHERE domain = 'finance';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'interview_advisor' IS NOT NULL OR v->>'paused_advisor' IS DISTINCT FROM 'agent.finance_advisor' THEN
    RAISE EXCEPTION 'FAIL [2 Grenze 2 h]: %', v; END IF;

  -- ---------- (3) aelter als die Stale-Grenze (Default 30) -> beide leer; Grenze aus core.config ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '31 days' WHERE domain = 'finance';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'interview_advisor' IS NOT NULL OR v->>'paused_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 stale]: %', v; END IF;
  UPDATE agent.advisor_plans SET updated_at = now() - interval '3 days' WHERE domain = 'finance';
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'rollout_draft_stale_days', '2');
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 Grenze aus core.config]: %', v; END IF;
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'rollout_draft_stale_days';

  -- ---------- (4) Haushalts-Entwurf fuer ein Mitglied -> leer (nur der Owner) ----------
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'lena', 'role', 'partner'));
  IF v->>'interview_advisor' IS NOT NULL OR v->>'paused_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [4 Haushalt fuer Mitglied]: %', v; END IF;

  -- ---------- (5) persoenlicher Entwurf: eigener ja, fremder nie ----------
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('career', 'lena', 'K', 'draft', 1, '{}', now() - interval '3 days');
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'lena', 'role', 'partner'));
  IF v->>'paused_advisor' IS DISTINCT FROM 'agent.career_advisor' THEN RAISE EXCEPTION 'FAIL [5 eigener Entwurf Mitglied]: %', v; END IF;
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS NOT NULL OR v->>'interview_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [5 fremder Entwurf fuer Owner]: %', v; END IF;

  -- ---------- (6) zwei Entwuerfe des Owners -> der juengste ----------
  DELETE FROM agent.advisor_plans WHERE domain = 'career';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at) VALUES
    ('finance', NULL, 'Plan', 'draft', 1, '{}', now() - interval '5 days'),
    ('career', 'erika', 'K', 'draft', 1, '{}', now() - interval '3 days');
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS DISTINCT FROM 'agent.career_advisor' THEN RAISE EXCEPTION 'FAIL [6 juengster]: %', v; END IF;
  -- ein heisser Entwurf gewinnt: interview gesetzt, paused leer (Regel 3c greift nur ohne interview_advisor)
  UPDATE agent.advisor_plans SET updated_at = now() - interval '10 minutes' WHERE domain = 'finance';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'interview_advisor' IS DISTINCT FROM 'agent.finance_advisor' OR v->>'paused_advisor' IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [6 heiss vor pausiert]: %', v; END IF;

  -- ---------- (7) Paket inaktiv -> dessen Entwurf zaehlt nicht ----------
  UPDATE agent.advisor_plans SET updated_at = now() - interval '5 days' WHERE domain = 'finance';
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'career';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS DISTINCT FROM 'agent.finance_advisor' THEN RAISE EXCEPTION 'FAIL [7 inaktives Paket uebersprungen]: %', v; END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS NOT NULL OR v->>'interview_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [7 alles inaktiv]: %', v; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package IN ('finance', 'career');

  -- ---------- (8) veroeffentlichter Plan ohne Entwurf -> leer ----------
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md, updated_at)
  VALUES ('finance', NULL, 'Plan', 'active', 1, '{}', 'p', now() - interval '3 days');
  v := core.fn_advisor_pins(jsonb_build_object('person_id', 'erika', 'role', 'owner'));
  IF v->>'paused_advisor' IS NOT NULL OR v->>'interview_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [8 aktiver Plan]: %', v; END IF;

  -- ---------- (9) leere / unvollstaendige Eingabe -> leer, wirft nie ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, updated_at)
  VALUES ('finance', NULL, 'Plan', 'draft', 2, '{}', now() - interval '3 days');
  v := core.fn_advisor_pins('{}'::jsonb);
  IF v->>'paused_advisor' IS NOT NULL OR v->>'interview_advisor' IS NOT NULL OR NOT (v ? 'interview_advisor') THEN
    RAISE EXCEPTION 'FAIL [9 leere Eingabe]: %', v; END IF;
  v := core.fn_advisor_pins(NULL);
  IF v IS NULL OR v->>'paused_advisor' IS NOT NULL THEN RAISE EXCEPTION 'FAIL [9 NULL]: %', v; END IF;

  ALTER TABLE agent.advisor_plans ENABLE TRIGGER trg_advisor_plans_touch;

  RAISE NOTICE 'PASS test_fn_advisor_pins (heiss, pausiert, 2-h-Grenze, stale, Mitglied/Haushalt, eigener/fremder Entwurf, juengster, inaktiv, aktiver Plan, leere Eingabe)';
END $$;

ROLLBACK;
