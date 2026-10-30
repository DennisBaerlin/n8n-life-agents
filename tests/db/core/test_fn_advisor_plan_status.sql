-- tests/db/core/test_fn_advisor_plan_status.sql
-- core.fn_advisor_plan_status(chat_id) — Plan-Zustand je Berater-Domaene mit Onboarding-Plan-Schritt (2026-10-28):
-- je core.advisors-Zeile mit plan_step=true und aktivem Paket {domain, package, state, open, ready, missing, per_user,
-- can_write} aus der Sicht des Betrachters:
--   * state: Entwurf vorhanden -> draft; aktiver Plan -> gaps (open = gaps_fn > 0) bzw. complete; sonst none;
--   * Scope aus core.context_scopes des plan_context: household -> person_id NULL, per_user -> die eigene Person;
--   * can_write = Owner (Plan-Tools owner_only) UND write_permission, ready/missing aus readiness_fn (ohne = reif);
--   * unaufgeloester Betrachter -> [] (fail-closed); eine werfende Paket-fn -> neutral; die Overview bleibt ohne Plan-Zustand.
BEGIN;

DO $$
DECLARE
  v   jsonb;
  f   jsonb;
  c   jsonb;
BEGIN
  -- ---------- Fixtures ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('financial_planning', 'fix', NULL, 'lazy', E'## Plan', jsonb_build_object('managed_by','agent','facts','{}'::jsonb))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active'), ('career','0.1.0','active'), ('estate','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name IN ('financial_planning', 'career_planning');
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_planning', 'per_user', 'own_user_only', 'career');
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step, gaps_fn, readiness_fn) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true, 'finance.fn_plan_gap_count', 'finance.fn_plan_readiness'),
    ('career',  'career_planning',    'career.fn_advisor_review',  'agent.career_advisor',  'career',  true, NULL, NULL),
    ('estate',  'estate_overview',    'estate.fn_advisor_review',  'agent.estate_advisor',  'estate',  false, NULL, NULL);
  DELETE FROM agent.advisor_plans WHERE domain IN ('finance', 'career');

  -- ---------- (1) Owner, keine Plaene: finance none (Haushalt, darf schreiben), career none (persoenlich), estate fehlt ----------
  v := core.fn_advisor_plan_status('111');
  IF jsonb_array_length(v) <> 2 THEN RAISE EXCEPTION 'FAIL [1 Anzahl/estate]: %', v; END IF;
  SELECT e INTO f FROM jsonb_array_elements(v) e WHERE e->>'domain' = 'finance';
  SELECT e INTO c FROM jsonb_array_elements(v) e WHERE e->>'domain' = 'career';
  IF f->>'state' <> 'none' OR (f->>'open')::int <> 0 OR (f->>'per_user')::boolean OR NOT (f->>'can_write')::boolean
     OR f->>'package' <> 'finance' THEN RAISE EXCEPTION 'FAIL [1 finance]: %', f; END IF;
  IF (f->'ready') IS DISTINCT FROM (finance.fn_plan_readiness('finance', NULL)->'ready')
     OR (f->'missing') IS DISTINCT FROM (finance.fn_plan_readiness('finance', NULL)->'missing') THEN
    RAISE EXCEPTION 'FAIL [1 finance readiness = fn]: %', f; END IF;
  IF c->>'state' <> 'none' OR NOT (c->>'per_user')::boolean OR NOT (c->>'can_write')::boolean
     OR NOT (c->>'ready')::boolean OR c->'missing' <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [1 career]: %', c; END IF;

  -- ---------- (2) Entwurf -> draft (hat Vorrang vor einem aktiven Plan) ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('finance', NULL, 'Plan', 'active', 1, '{"risk_profile":{"content":"x"}}', 'p'),
         ('finance', NULL, 'Entwurf', 'draft', 2, '{}', NULL);
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'finance';
  IF f->>'state' <> 'draft' THEN RAISE EXCEPTION 'FAIL [2 draft]: %', f; END IF;

  -- ---------- (3) nur aktiver Plan mit Luecken -> gaps, open = gaps_fn ----------
  DELETE FROM agent.advisor_plans WHERE domain = 'finance' AND status = 'draft';
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'finance';
  IF f->>'state' <> 'gaps' OR (f->>'open')::int <> finance.fn_plan_gap_count('finance', NULL) OR (f->>'open')::int < 1 THEN
    RAISE EXCEPTION 'FAIL [3 gaps]: %', f; END IF;

  -- ---------- (4) vollstaendiger Plan (alle 9 Sektionen bestaetigt, alle Bloecke verwertbar) -> complete, open 0 ----------
  UPDATE agent.advisor_plans SET interview_state = '{"household_basics":{},"risk_protection":{},"emergency_reserve":{},
      "debts_loans":{},"retirement_pension":{},"risk_profile":{},"wealth_building":{},"korea_crossborder":{},"goals_triggers":{}}'
   WHERE domain = 'finance';
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('managed_by','agent','facts', jsonb_build_object(
      'risk_profile', '{}'::jsonb,
      'target_allocation', '{}'::jsonb, 'glidepath', '{}'::jsonb, 'goal', '{}'::jsonb))
   WHERE name = 'financial_planning';
  -- Notreserve = Ruecklage (finance, 2026-10-30), kein Plan-Block mehr
  INSERT INTO finance.savings_goals (name, kind, target_months, status) VALUES ('__aps_er__', 'emergency_reserve', 6, 'active');
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'finance';
  IF f->>'state' <> 'complete' OR (f->>'open')::int <> 0 THEN RAISE EXCEPTION 'FAIL [4 complete]: %', f; END IF;

  -- ---------- (5) Mitglied: Haushalts-Plan sichtbar, aber nicht schreibbar; career = SEIN Scope, ebenfalls owner-only ----------
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state, plan_md)
  VALUES ('career', 'erika', 'Karriere Erika', 'active', 1, '{}', 'e');
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('222')) e WHERE e->>'domain' = 'finance';
  SELECT e INTO c FROM jsonb_array_elements(core.fn_advisor_plan_status('222')) e WHERE e->>'domain' = 'career';
  IF (f->>'can_write')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 Mitglied finance]: %', f; END IF;
  -- eigener (leerer) Plan-Scope, aber Plaene schreibt nur der Owner (Plan-Tools owner_only) -> nicht schreibbar
  IF c->>'state' <> 'none' OR (c->>'can_write')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 Mitglied career = eigener, owner-only]: %', c; END IF;
  -- Owner-Karriereplan liegt unter person_id = Owner (nicht NULL) -> fuer den Owner complete (career hat keine gaps_fn)
  SELECT e INTO c FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'career';
  IF c->>'state' <> 'complete' THEN RAISE EXCEPTION 'FAIL [5 Owner career]: %', c; END IF;

  -- ---------- (6) inaktives Paket faellt raus; unaufgeloester Betrachter -> [] ----------
  UPDATE core.package_registry SET status = 'installed' WHERE package = 'career';
  v := core.fn_advisor_plan_status('111');
  IF jsonb_array_length(v) <> 1 OR v->0->>'domain' <> 'finance' THEN RAISE EXCEPTION 'FAIL [6 inaktiv]: %', v; END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'career';
  IF core.fn_advisor_plan_status('999') <> '[]'::jsonb OR core.fn_advisor_plan_status(NULL) <> '[]'::jsonb
     OR core.fn_advisor_plan_status('abc') <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [6 unaufgeloest]: %', core.fn_advisor_plan_status('999'); END IF;

  -- ---------- (7) fehlende gaps_fn (Typo/Apply-Order) -> kein Fehler, Plan gilt als ohne Luecken ----------
  UPDATE core.advisors SET gaps_fn = 'finance.fn_does_not_exist' WHERE domain = 'finance';
  UPDATE agent.advisor_plans SET interview_state = '{}' WHERE domain = 'finance';
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'finance';
  IF f->>'state' <> 'complete' THEN RAISE EXCEPTION 'FAIL [7 gaps_fn fehlt]: %', f; END IF;
  UPDATE core.advisors SET gaps_fn = 'finance.fn_plan_gap_count' WHERE domain = 'finance';

  -- ---------- (8) eine WERFENDE Paket-fn bricht weder Menue noch Knopf-Handler: neutral (reif / 0 Luecken) ----------
  CREATE FUNCTION finance.fn_t_plan_raise(text, text) RETURNS jsonb LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'boom'; END $f$;
  CREATE FUNCTION finance.fn_t_plan_raise_int(text, text) RETURNS int LANGUAGE plpgsql AS $f$ BEGIN RAISE EXCEPTION 'boom'; END $f$;
  UPDATE core.advisors SET readiness_fn = 'finance.fn_t_plan_raise', gaps_fn = 'finance.fn_t_plan_raise_int' WHERE domain = 'finance';
  SELECT e INTO f FROM jsonb_array_elements(core.fn_advisor_plan_status('111')) e WHERE e->>'domain' = 'finance';
  IF (f->>'ready')::boolean IS DISTINCT FROM true OR f->'missing' <> '[]'::jsonb OR f->>'state' <> 'complete' THEN
    RAISE EXCEPTION 'FAIL [8 werfende Paket-fn]: %', f; END IF;
  UPDATE core.advisors SET readiness_fn = 'finance.fn_plan_readiness', gaps_fn = 'finance.fn_plan_gap_count' WHERE domain = 'finance';

  -- ---------- (9) die Overview traegt KEINEN Plan-Zustand (ihre Cron-/Karten-Aufrufer brauchen nur Abschnitte) ----------
  IF core.fn_onboarding_overview('111') ? 'plans' THEN RAISE EXCEPTION 'FAIL [9 overview ohne plans]'; END IF;

  RAISE NOTICE 'PASS test_fn_advisor_plan_status (none/draft/gaps/complete, Haushalt vs. persoenlich, Mitglied, inaktiv, fail-closed, werfende Paket-fn neutral, Overview ohne plans)';
END $$;

ROLLBACK;
