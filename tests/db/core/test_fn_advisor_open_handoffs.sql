-- tests/db/core/test_fn_advisor_open_handoffs.sql
-- core.fn_advisor_open_handoffs(p_domain): offene vereinbarte Plan-Aufgaben (open + working) der Haushalts-Plan-Domain
-- plus die zurueckgestellten (deferred, mit Status) fuer das Lesefenster des Beraters, ohne payload und ohne Person; per_user-Domain -> []; finance.fn_advisor_snapshot
-- traegt die Liste als open_handoffs. Rollen-Perspektive (finance_ro): tests/db/cross/test_role_permissions.sql.
BEGIN;

DO $$
DECLARE
  r     jsonb;
  v_id  int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','en')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.context_scopes WHERE context_name = 'financial_planning';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package) VALUES
    ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance');
  DELETE FROM agent.handoff_tasks;

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, payload, text, created_at)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'Haushaltskonto', 'recurring_transfer',
          jsonb_build_object('amount', 1000), 'Dauerauftrag 1000 € zum Monatsanfang', now() - interval '4 days')
  RETURNING id INTO v_id;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at)
  VALUES ('finance', 'finance', 'lena', 'emergency_reserve', 'savings_goal', 'Sparziel Notgroschen', 'working', now());
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at) VALUES
    ('finance', 'finance', 'erika', 'goals_triggers', 'savings_plan', 'Sparplan erledigt', 'done', now()),
    ('finance', 'finance', 'erika', 'goals_triggers', 'other', 'Uebersprungen', 'cancelled', now());
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, blocked_code)
  VALUES ('finance', 'finance', 'erika', 'goals_triggers', 'recurring_transfer', 'Zurueckgestellt bis 0', 'deferred', 'until_amount');
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES ('career', 'career', 'erika', 'goals', 'other', 'Fremde Domain');

  -- ---------- 1) open + working der Domain, Reihenfolge der Anlage, nur die Lese-Felder ----------
  r := core.fn_advisor_open_handoffs('finance');
  IF jsonb_typeof(r) <> 'array' OR jsonb_array_length(r) <> 3 THEN RAISE EXCEPTION 'FAIL [1 Anzahl]: %', r; END IF;
  IF r->0->>'text' <> 'Dauerauftrag 1000 € zum Monatsanfang' OR r->0->>'kind' <> 'recurring_transfer'
     OR r->0->>'topic' <> 'Haushaltskonto' OR r->0->>'section_key' <> 'goals_triggers' OR r->0->>'status' <> 'open'
     OR (r->0->>'open_since')::date <> core.fn_today(now() - interval '4 days') THEN
    RAISE EXCEPTION 'FAIL [1 Felder]: %', r->0; END IF;
  IF r->1->>'status' <> 'working' OR r->1->>'text' <> 'Sparziel Notgroschen' OR (r->1 ? 'topic') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1 working]: %', r->1; END IF;
  IF r->2->>'status' IS DISTINCT FROM 'deferred' OR r->2->>'text' <> 'Zurueckgestellt bis 0' THEN
    RAISE EXCEPTION 'FAIL [1 zurueckgestellte mit Status]: %', r->2; END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r) e, jsonb_object_keys(e) k
              WHERE k NOT IN ('kind', 'text', 'topic', 'section_key', 'status', 'open_since')) THEN
    RAISE EXCEPTION 'FAIL [1 nur Lese-Felder, kein payload/person_id/id]: %', r; END IF;
  RAISE NOTICE 'PASS [1 offene Vormerkungen der Domain]';

  -- ---------- 2) Domain ohne offene Aufgabe -> [] ----------
  IF core.fn_advisor_open_handoffs('unknown_domain') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [2 leer]'; END IF;
  RAISE NOTICE 'PASS [2 leere Domain -> []]';

  -- ---------- 3) Snapshot traegt die Liste ----------
  r := finance.fn_advisor_snapshot();
  IF r->'open_handoffs' IS DISTINCT FROM core.fn_advisor_open_handoffs('finance') THEN
    RAISE EXCEPTION 'FAIL [3 snapshot open_handoffs]: %', r->'open_handoffs'; END IF;
  RAISE NOTICE 'PASS [3 snapshot open_handoffs]';
  PERFORM set_config('t.fin_ids', (SELECT string_agg(id::text, ',') FROM agent.handoff_tasks WHERE domain = 'finance'), true);
END $$;

-- 5) Login-Rolle: finance_ro (Frei-SQL des Beraters) sieht die Liste ueber den Snapshot, die Paket-Rolle eines anderen
-- Pakets bekommt []. SET SESSION AUTHORIZATION aendert session_user (SET ROLE nicht) — darauf bindet die fn.
SET LOCAL SESSION AUTHORIZATION finance_ro;
DO $$
BEGIN
  IF jsonb_array_length(finance.fn_advisor_snapshot()->'open_handoffs') <> 3 THEN
    RAISE EXCEPTION 'FAIL [5a finance_ro snapshot]: %', finance.fn_advisor_snapshot()->'open_handoffs'; END IF;
  RAISE NOTICE 'PASS [5a finance_ro liest die Vormerkungen ueber den Snapshot]';
END $$;
RESET SESSION AUTHORIZATION;
SET LOCAL SESSION AUTHORIZATION career_ro;
DO $$
BEGIN
  IF core.fn_advisor_open_handoffs('finance') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [5b career_ro las finance-Vormerkungen]'; END IF;
  IF core.fn_handoff_tasks_read(string_to_array(current_setting('t.fin_ids'), ',')::int[]) <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5b career_ro las finance-Vormerkungen per fn_handoff_tasks_read]'; END IF;
  IF core.fn_handoff_register('finance', '111') <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [5b career_ro las das finance-Ersatzweg-Register]'; END IF;
  RAISE NOTICE 'PASS [5b fremde Paket-Rolle -> []]';
END $$;
RESET SESSION AUTHORIZATION;

DO $$
BEGIN
  -- ---------- 4) per_user-Plan-Kontext -> [] (Snapshot kennt keinen Absender, fail-closed) ----------
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('financial_planning', 'per_user', 'own_user_only', 'finance');
  IF core.fn_advisor_open_handoffs('finance') <> '[]'::jsonb THEN RAISE EXCEPTION 'FAIL [4 per_user]'; END IF;
  RAISE NOTICE 'PASS [4 per_user -> []]';
END $$;

ROLLBACK;
