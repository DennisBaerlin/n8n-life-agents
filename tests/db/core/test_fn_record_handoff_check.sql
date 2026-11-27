-- tests/db/core/test_fn_record_handoff_check.sql
-- agent.fn_record_handoff_check(p): Ergebnis des Auftrags "Eintrag pruefen" ohne Korrektur (passt zum Plan, oder die
-- Korrektur-Karte wurde abgelehnt) - je Eintrag ein Merker '<domain>:<who>:check_done:<task_id>' (plan_rollout, ohne Ablauf):
--   * nur Altbestand der Person des Absenders (done ohne close_reason), der beim Berater war (Merker ...:checked:<id>) und
--     noch keine Korrektur hat (follows_task_id);
--   * alles oder nichts: ein ungueltiger Eintrag -> {ok:false, code}, kein Merker;
--   * outcome matches|kept; wiederholt = kein Fehler (der Merker bleibt).
-- Werte erfunden. BEGIN..ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  d CONSTANT text := '__chk__';
  r jsonb;
  v_a int;
  v_b int;
  v_open int;
  v_fol int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner','birth_date','1985-06-21','telegram_user_id',222,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES (d, 'core', '__chk___planning', 'core.fn_x', TRUE);
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'Alt A', 'done', now()) RETURNING id INTO v_a;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'Alt B', 'done', now()) RETURNING id INTO v_b;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text)
  VALUES (d, 'core', 'erika', 's', 'other', 'offen') RETURNING id INTO v_open;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, follows_task_id)
  VALUES (d, 'core', 'erika', 's', 'other', 'Korrektur zu B', v_b) RETURNING id INTO v_fol;
  -- beim Berater (core.fn_handle_plan_cb setzt diesen Merker beim Tipp auf [Jetzt pruefen])
  INSERT INTO core.notification_state (source, key, state, last_fired_at)
  VALUES ('plan_rollout', d || ':household:checked:' || v_a, 'fired', now()),
         ('plan_rollout', d || ':household:checked:' || v_b, 'fired', now());

  -- 1) Ablehnungen ohne Merker
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_a),'outcome','gut'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'invalid_outcome' THEN RAISE EXCEPTION 'FAIL [1 outcome]: %', r; END IF;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids','[]','outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 leer]: %', r; END IF;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','222','domain',d,'handoff_task_ids',jsonb_build_array(v_a),'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_invalid' THEN RAISE EXCEPTION 'FAIL [1 fremde Person]: %', r; END IF;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_open),'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_not_legacy' THEN RAISE EXCEPTION 'FAIL [1 offen]: %', r; END IF;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_b),'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_task_followed' THEN RAISE EXCEPTION 'FAIL [1 korrigiert]: %', r; END IF;
  -- alles oder nichts: A gueltig, B schon korrigiert -> kein Merker fuer A
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_a, v_b),'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR core.fn_plan_rollout_latch(d || ':household:check_done:' || v_a) <> 'free' THEN
    RAISE EXCEPTION 'FAIL [1 alles oder nichts]: %', r; END IF;
  -- nicht beim Berater gewesen
  DELETE FROM core.notification_state WHERE source = 'plan_rollout' AND key = d || ':household:checked:' || v_a;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_a),'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'code' <> 'handoff_not_checked' THEN RAISE EXCEPTION 'FAIL [1 nicht uebergeben]: %', r; END IF;
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('plan_rollout', d || ':household:checked:' || v_a, 'fired', now());
  RAISE NOTICE 'PASS [1 Ablehnungen]';

  -- 2) passt zum Plan: Merker gesetzt, ohne Ablauf; als Zahl-String und wiederholt
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',v_a::text,'outcome','matches'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'recorded')::int <> 1 OR core.fn_plan_rollout_latch(d || ':household:check_done:' || v_a) <> 'done' THEN
    RAISE EXCEPTION 'FAIL [2 matches]: %', r; END IF;
  r := agent.fn_record_handoff_check(jsonb_build_object('chat_id','111','domain',d,'handoff_task_ids',jsonb_build_array(v_a),'outcome','kept'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'recorded')::int <> 1 THEN RAISE EXCEPTION 'FAIL [2 wiederholt]: %', r; END IF;
  RAISE NOTICE 'PASS [2 Merker]';
END $$;

ROLLBACK;
