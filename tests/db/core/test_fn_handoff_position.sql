-- tests/db/core/test_fn_handoff_position.sql
-- core.fn_handoff_position: "Eintrag k von n" in der beanspruchten Runde (gleiche Person, Domain, claimed_at), k nach id;
--   stabil nach einer erledigten und einer zurueckgegebenen (uebersprungenen) Aufgabe; eine andere Runde und eine andere
--   Person zaehlen nicht mit; nie beansprucht -> NULL. Der Claim des Knopfs (core.fn_handle_handoff_cb) liefert die Runde.
BEGIN;

DO $$
DECLARE
  r    jsonb;
  v_a  int; v_b int; v_c int; v_old int; v_open int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.package_registry (package, version, status) VALUES ('finance','0.1.0','active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.advisors;
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true);
  DELETE FROM agent.handoff_tasks;
  -- eine alte, schon erledigte Runde
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at, close_reason)
  VALUES ('finance','finance','erika','g','other','alt','done', now() - interval '3 days', now() - interval '3 days', 'done_elsewhere')
  RETURNING id INTO v_old;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance','finance','erika','g','other','A') RETURNING id INTO v_a;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance','finance','erika','g','other','B') RETURNING id INTO v_b;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance','finance','erika','g','other','C') RETURNING id INTO v_c;

  IF core.fn_handoff_position(v_a) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [0 nie beansprucht]: %', core.fn_handoff_position(v_a); END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_c,'chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [0 Claim]: %', r; END IF;
  -- spaeter vereinbart, nicht in der Runde
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('finance','finance','erika','g','other','D') RETURNING id INTO v_open;

  r := core.fn_handoff_position(v_a);
  IF (r->>'k')::int <> 1 OR (r->>'n')::int <> 3 THEN RAISE EXCEPTION 'FAIL [1 A]: %', r; END IF;
  r := core.fn_handoff_position(v_c);
  IF (r->>'k')::int <> 3 OR (r->>'n')::int <> 3 THEN RAISE EXCEPTION 'FAIL [1 C]: %', r; END IF;
  RAISE NOTICE 'PASS [1 k von n]';

  -- A erledigt, B uebersprungen: C bleibt 3 von 3
  PERFORM core.fn_complete_handoff_task(jsonb_build_object('handoff_task_id', v_a, 'chat_id', '111'));
  PERFORM core.fn_cancel_handoff_task(jsonb_build_object('handoff_task_id', v_b, 'chat_id', '111', 'reason', 'skipped'));
  r := core.fn_handoff_position(v_c);
  IF (r->>'k')::int <> 3 OR (r->>'n')::int <> 3 THEN RAISE EXCEPTION 'FAIL [2 stabil]: %', r; END IF;
  r := core.fn_handoff_position(v_old);
  IF (r->>'k')::int <> 1 OR (r->>'n')::int <> 1 THEN RAISE EXCEPTION 'FAIL [2 alte Runde]: %', r; END IF;
  IF core.fn_handoff_position(v_open) IS NOT NULL OR core.fn_handoff_position(999999) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 nicht in der Runde]'; END IF;
  RAISE NOTICE 'PASS [2 stabil nach erledigt und uebersprungen]';
END $$;

ROLLBACK;
