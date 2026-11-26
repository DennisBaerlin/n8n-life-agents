-- tests/db/core/test_fn_handoff_register.sql
-- core.fn_handoff_register (abgeleitet, wiederholbar) und der Knopf handoff:<domain>:<max>:fix (core.fn_handle_handoff_cb):
--   * deferred -> Zeile; possible_now wechselt von falsch auf wahr, sobald die Vorpruefung (recheck) einen Aufruf liefert;
--   * done mit wanted und nicht leerem Unterschied (handoff_diff_fn) -> deviation; gleicher Stand -> keine Zeile;
--   * Altbestand (abgeschlossen ohne close_reason) mit Thema im gueltigen Plan -> legacy; ohne Thema im Plan -> keine Zeile;
--     legacy done bleibt possible_now=false (Kandidat fuer den Berater);
--   * eine Aufgabe, der schon eine Korrektur folgt, faellt heraus; fremde Person und andere Domain sehen nichts;
--   * ohne Registry-fns: possible_now=false, keine deviation;
--   * Knopf ...:fix: deferred -> working, abgeschlossen -> neue Aufgabe working mit follows_task_id und wanted = Aufruf;
--     zweiter Tipp findet nichts; je abgeschlossener Aufgabe hoechstens eine Korrektur (UNIQUE).
BEGIN;

CREATE FUNCTION core.fn_t_reg_check(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  IF COALESCE(current_setting('t.reg_mode', true), '') <> 'now' THEN
    RETURN '{"ok":true,"unsupported":true,"blocked_code":"end_date_future"}'::jsonb;
  END IF;
  RETURN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', 'set_x', 'input', jsonb_build_object('task', p->'task_id', 'mode', p->>'mode')));
END $f$;
CREATE FUNCTION core.fn_t_reg_diff(p_task int) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN (SELECT text FROM agent.handoff_tasks WHERE id = p_task) LIKE 'abweichend%'
              THEN '[{"field":"target_amount","wanted":1200,"current":1000}]'::jsonb ELSE '[]'::jsonb END $f$;

DO $$
DECLARE
  r      jsonb;
  v_def  int; v_dev int; v_same int; v_leg_c int; v_leg_d int; v_leg_x int; v_fol int; v_new int;
  v_ok   boolean;
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
  INSERT INTO core.advisors (domain, plan_context, review_fn, advisor_agent, package, plan_step)
  VALUES ('finance', 'financial_planning', 'finance.fn_advisor_review', 'agent.finance_advisor', 'finance', true);
  INSERT INTO core.callback_handlers (prefix, handler_fn, package, member_permeable)
  VALUES ('handoff', 'core.fn_handle_handoff_cb', 'core', true)
  ON CONFLICT (prefix) DO UPDATE SET handler_fn = EXCLUDED.handler_fn, member_permeable = true;
  DELETE FROM agent.handoff_tasks;
  DELETE FROM agent.advisor_plans WHERE domain = 'finance';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
  VALUES ('finance', NULL, 'T', 'active', 2, jsonb_build_object(
    'goals_triggers', jsonb_build_object('topics', jsonb_build_array(jsonb_build_object('topic', 'Ziele', 'content', 'c'))),
    'wealth_building', jsonb_build_object('content', 'w')));

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, blocked_code, wanted, why)
  VALUES ('finance','finance','erika','goals_triggers','Ziele','recurring_transfer','zurueckgestellt','deferred','end_date_future',
          '{"tool":"create_recurring_transfer","input":{"amount":50}}', 'Damit das Ziel rechtzeitig voll ist.') RETURNING id INTO v_def;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, claimed_at, closed_at, close_reason, wanted, entered_refs)
  VALUES ('finance','finance','erika','goals_triggers','Ziele','savings_goal','abweichend eingetragen','done', now(), now(), 'entered',
          '{"tool":"create_savings_goal","input":{"target_amount":1200}}', '[{"type":"savings_goal","id":5}]') RETURNING id INTO v_dev;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, claimed_at, closed_at, close_reason, wanted, entered_refs)
  VALUES ('finance','finance','erika','goals_triggers','Ziele','savings_goal','wie vereinbart','done', now(), now(), 'entered',
          '{"tool":"create_savings_goal","input":{"target_amount":900}}', '[{"type":"savings_goal","id":6}]') RETURNING id INTO v_same;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, closed_at)
  VALUES ('finance','finance','erika','goals_triggers','ziele','savings_plan','alt gestrichen','cancelled', now()) RETURNING id INTO v_leg_c;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at)
  VALUES ('finance','finance','erika','wealth_building','other','alt erledigt','done', now(), now()) RETURNING id INTO v_leg_d;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, topic, kind, text, status, closed_at)
  VALUES ('finance','finance','erika','goals_triggers','Thema gibt es nicht mehr','other','alt ohne Thema','cancelled', now()) RETURNING id INTO v_leg_x;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES ('finance','finance','erika','wealth_building','other','alt korrigiert','cancelled', now()) RETURNING id INTO v_fol;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, follows_task_id)
  VALUES ('finance','finance','erika','wealth_building','other','alt korrigiert (neu)', v_fol);
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, blocked_code)
  VALUES ('finance','finance','lena','goals_triggers','other','fremd','deferred','end_date_future');

  -- ---------- 1) ohne Registry-fns ----------
  r := core.fn_handoff_register('finance', '111');
  IF (SELECT string_agg((e->>'task_id') || '=' || (e->>'row_kind'), ',' ORDER BY (e->>'task_id')::int) FROM jsonb_array_elements(r) e)
     <> v_def || '=deferred,' || v_leg_c || '=legacy,' || v_leg_d || '=legacy' THEN RAISE EXCEPTION 'FAIL [1 Zeilen ohne fns]: %', r; END IF;
  IF jsonb_path_exists(r, '$[*] ? (@.possible_now == true)') THEN RAISE EXCEPTION 'FAIL [1 possible_now ohne Vorpruefung]: %', r; END IF;
  RAISE NOTICE 'PASS [1 ohne Registry-fns]';

  -- ---------- 2) mit Vorpruefung und Unterschied ----------
  UPDATE core.advisors SET handoff_check_fn = 'core.fn_t_reg_check', handoff_diff_fn = 'core.fn_t_reg_diff' WHERE domain = 'finance';
  r := core.fn_handoff_register('finance', '111');
  IF (SELECT string_agg((e->>'task_id') || '=' || (e->>'row_kind'), ',' ORDER BY (e->>'task_id')::int) FROM jsonb_array_elements(r) e)
     <> v_def || '=deferred,' || v_dev || '=deviation,' || v_leg_c || '=legacy,' || v_leg_d || '=legacy' THEN
    RAISE EXCEPTION 'FAIL [2 Zeilen]: %', r; END IF;
  IF jsonb_path_exists(r, '$[*] ? (@.possible_now == true)') THEN RAISE EXCEPTION 'FAIL [2 geht noch nicht]: %', r; END IF;
  IF (SELECT e->'diff' FROM jsonb_array_elements(r) e WHERE (e->>'task_id')::int = v_dev) <> '[{"field":"target_amount","wanted":1200,"current":1000}]'::jsonb
     OR (SELECT e->>'why' FROM jsonb_array_elements(r) e WHERE (e->>'task_id')::int = v_def) <> 'Damit das Ziel rechtzeitig voll ist.'
     OR (SELECT e->>'blocked_code' FROM jsonb_array_elements(r) e WHERE (e->>'task_id')::int = v_def) <> 'end_date_future' THEN
    RAISE EXCEPTION 'FAIL [2 Felder]: %', r; END IF;
  PERFORM set_config('t.reg_mode', 'now', true);
  r := core.fn_handoff_register('finance', '111');
  IF (SELECT string_agg((e->>'task_id') || '=' || (e->>'possible_now'), ',' ORDER BY (e->>'task_id')::int) FROM jsonb_array_elements(r) e)
     <> v_def || '=true,' || v_dev || '=true,' || v_leg_c || '=true,' || v_leg_d || '=false' THEN RAISE EXCEPTION 'FAIL [2 jetzt moeglich]: %', r; END IF;
  IF (SELECT e->'call'->>'tool' FROM jsonb_array_elements(r) e WHERE (e->>'task_id')::int = v_def) <> 'set_x'
     OR (SELECT e->'call'->'input'->>'mode' FROM jsonb_array_elements(r) e WHERE (e->>'task_id')::int = v_def) <> 'recheck' THEN
    RAISE EXCEPTION 'FAIL [2 call]: %', r; END IF;
  IF jsonb_array_length(core.fn_handoff_register('finance', '222')) <> 1 THEN RAISE EXCEPTION 'FAIL [2 Person]'; END IF;
  IF jsonb_array_length(core.fn_handoff_register('career', '111')) <> 0 OR jsonb_array_length(core.fn_handoff_register('finance', '999')) <> 0 THEN
    RAISE EXCEPTION 'FAIL [2 andere Domain/unbekannt]'; END IF;
  RAISE NOTICE 'PASS [2 Register mit Vorpruefung und Unterschied]';

  -- ---------- 3) Knopf ...:fix ----------
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_leg_c || ':fix','chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'handoff' OR jsonb_array_length(r->'task_ids') <> 3 THEN RAISE EXCEPTION 'FAIL [3 Claim]: %', r; END IF;
  IF (SELECT status || '/' || COALESCE(blocked_code, '-') FROM agent.handoff_tasks WHERE id = v_def) <> 'working/-' THEN RAISE EXCEPTION 'FAIL [3 deferred -> working]'; END IF;
  SELECT id INTO v_new FROM agent.handoff_tasks WHERE follows_task_id = v_leg_c;
  IF v_new IS NULL OR (SELECT status FROM agent.handoff_tasks WHERE id = v_new) <> 'working'
     OR (SELECT wanted->>'tool' FROM agent.handoff_tasks WHERE id = v_new) <> 'set_x'
     OR (SELECT text FROM agent.handoff_tasks WHERE id = v_new) <> 'alt gestrichen'
     OR NOT EXISTS (SELECT 1 FROM agent.handoff_tasks WHERE follows_task_id = v_dev AND status = 'working') THEN
    RAISE EXCEPTION 'FAIL [3 Korrektur als neue Aufgabe]: %', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = v_leg_c) <> 'cancelled' THEN RAISE EXCEPTION 'FAIL [3 alte Aufgabe angefasst]'; END IF;
  IF NOT jsonb_path_exists(r->'tasks', '$[*] ? (@.wanted.tool == "set_x")') THEN RAISE EXCEPTION 'FAIL [3 tasks ohne wanted]: %', r; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_leg_c || ':fix','chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'nothing_open' THEN RAISE EXCEPTION 'FAIL [3 Doppeltipp]: %', r; END IF;
  r := core.fn_handle_handoff_cb(jsonb_build_object('data','handoff:finance:' || v_leg_c || ':fax','chat_id','111','chat_type','private'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'reason' <> 'unknown_handoff' THEN RAISE EXCEPTION 'FAIL [3 manipuliert]: %', r; END IF;
  v_ok := false;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, follows_task_id)
    VALUES ('finance','finance','erika','g','other','zweite Korrektur', v_leg_c);
  EXCEPTION WHEN unique_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [3 zweite Korrektur derselben Aufgabe]'; END IF;
  RAISE NOTICE 'PASS [3 Knopf fix]';
END $$;

ROLLBACK;
