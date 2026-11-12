-- tests/db/core/test_fn_plan_rollout_next.sql
-- core.fn_plan_rollout_next: genau ein naechster Schritt, Claim mit Frist, Warten, Entwurf, Personen-Scope, Paket-Schritt.
BEGIN;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'x', NULL, 'lazy', 'f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
  jsonb_build_object('person_id', 'erika', 'first_name', 'Erika', 'last_name', 'M', 'role', 'owner', 'birth_date', '1980-05-20', 'telegram_user_id', 111, 'language', 'de'),
  jsonb_build_object('person_id', 'lena', 'first_name', 'Lena', 'last_name', 'B', 'role', 'partner', 'birth_date', '1985-06-21', 'telegram_user_id', 222)))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__roll__', 'core', '__roll___planning', 'core.fn_x', TRUE);
INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'plan_sync_required', 'true'),
  ('core', 'cron_enable', 'drift_check', 'false'), ('core', 'cron_enable', 'plan_review', 'false')
ON CONFLICT (category, key) DO UPDATE SET package = excluded.package, value = excluded.value;

DO $$
DECLARE
  d CONSTANT TEXT := '__roll__';
  v JSONB;
  v_plan INT;
  v_key TEXT;
BEGIN
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->'step' <> 'null'::jsonb OR jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL ohne Plan %', v; END IF;

  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'active', 1) RETURNING id INTO v_plan;

  -- Schritt 0, zweiter Aufruf bekommt nichts und geht nicht weiter
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 0 OR v->'messages'->0->'buttons'->0->>'data' <> 'plan:scan:' || d || ':1' THEN RAISE EXCEPTION 'FAIL s0 %', v; END IF;
  v_key := v->'messages'->0->'latch'->>'key';
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'loser')::boolean IS NOT TRUE OR jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Verlierer %', v; END IF;

  -- Frist: ohne Commit kommt der Schritt nach Ablauf wieder
  UPDATE core.notification_state SET expires_at = now() - interval '1 minute' WHERE source = 'plan_rollout' AND key = v_key;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 0 OR jsonb_array_length(v->'messages') <> 1 THEN RAISE EXCEPTION 'FAIL Frist %', v; END IF;
  -- Resolve setzt zurueck
  PERFORM core.fn_notify_resolve('plan_rollout', v_key);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 1 THEN RAISE EXCEPTION 'FAIL resolve %', v; END IF;
  -- Commit: wartet bis rollout_wait_days
  PERFORM core.fn_notify_commit('plan_rollout', v_key);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'wait')::boolean IS NOT TRUE OR (v->>'step')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL s0 wait %', v; END IF;
  UPDATE agent.advisor_plans SET synced_at = now() WHERE id = v_plan;

  -- Mitglied am Haushaltsplan: nichts
  v := core.fn_plan_rollout_next(d, 'lena');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Mitglied %', v; END IF;

  -- Schritt 1 und 2
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES (d, 'core', 'erika', 's', 'other', 'Aufgabe A');
  -- offener Entwurf: Schritt 1 wartet (die Liste kommt am Ende des Gespraechs, ausser der Berater schickt sie selbst)
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'draft', 2);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR (v->>'wait')::boolean IS NOT TRUE OR jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL s1 Entwurf %', v; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'plan_rollout' AND key LIKE d || ':%:handoff:%') THEN RAISE EXCEPTION 'FAIL s1 Entwurf Merker'; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = d AND status = 'draft';
  -- gerade beanspruchte Aufgabe (Durchgehen laeuft) steht nicht in der Liste, wie beim Berater-Tool (core.fn_handoff_overview)
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at) VALUES (d, 'core', 'erika', 's', 'other', 'Aufgabe W', 'working', now());
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->'messages'->0->'msg'->0->'params'->>'list' <> '1. Aufgabe A' THEN RAISE EXCEPTION 'FAIL s1 working %', v; END IF;
  IF v->'messages'->0->'buttons'->0->>'data' <> 'handoff:' || d || ':' || (SELECT min(id) FROM agent.handoff_tasks WHERE domain = d) THEN RAISE EXCEPTION 'FAIL s1 max ohne working %', v; END IF;
  PERFORM core.fn_notify_resolve('plan_rollout', v->'messages'->0->'latch'->>'key');
  DELETE FROM agent.handoff_tasks WHERE domain = d AND text = 'Aufgabe W';
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR v->'messages'->0->'buttons'->0->>'data' NOT LIKE 'handoff:' || d || ':%' THEN RAISE EXCEPTION 'FAIL s1 %', v; END IF;
  v_key := v->'messages'->0->'latch'->>'key';
  PERFORM core.fn_notify_commit('plan_rollout', v_key);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 2 OR (v->>'wait')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL s2 %', v; END IF;
  -- neue Aufgabe mit hoeherer id sendet wieder
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES (d, 'core', 'erika', 's', 'other', 'Aufgabe B');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL s1 neu %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v->'messages'->0->'latch'->>'key');
  -- Warten endet nach rollout_wait_days
  UPDATE agent.handoff_tasks SET created_at = now() - interval '8 days' WHERE domain = d;
  -- rollout_fn wirft: neutral, die Schritte danach laufen
  UPDATE core.advisors SET rollout_fn = 'core.fn_x_rollout_missing' WHERE domain = d;
  UPDATE agent.advisor_plans SET watch_candidates = '["Oelpreis"]' WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 4 OR v->'messages'->0->'buttons'->0->>'data' <> 'plan:watch:' || d || ':1' THEN RAISE EXCEPTION 'FAIL s4 %', v; END IF;
  v_key := v->'messages'->0->'latch'->>'key';
  PERFORM core.fn_notify_commit('plan_rollout', v_key);
  -- Abstand bis Schritt 5
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'wait')::boolean IS NOT TRUE OR (v->>'step')::int IS DISTINCT FROM 4 THEN RAISE EXCEPTION 'FAIL gap %', v; END IF;
  UPDATE core.notification_state SET last_fired_at = now() - interval '21 hours' WHERE source = 'plan_rollout' AND key = v_key;

  -- offener Entwurf: 0, 4, 5 entfallen, Entwurf ueber 30 Tage: wieder da
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, updated_at) VALUES (d, 'p', 'draft', 2, now());
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL Entwurf %', v; END IF;
  -- trg_advisor_plans_touch setzt updated_at selbst -> Alter ueber die Frist simulieren
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'rollout_draft_stale_days', '0') ON CONFLICT (category, key) DO UPDATE SET value = '0';

  -- Schritt 5: Einschalten
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 5 OR v->'messages'->0->'buttons'->0->>'data' <> 'watch:on:' || d || ':1' THEN RAISE EXCEPTION 'FAIL s5 %', v; END IF;
  IF jsonb_array_length(v->'messages'->0->'latches') <> 2 THEN RAISE EXCEPTION 'FAIL latches %', v; END IF;
  FOR v_key IN SELECT x->>'key' FROM jsonb_array_elements(v->'messages'->0->'latches') x LOOP PERFORM core.fn_notify_commit('plan_rollout', v_key); END LOOP;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL s5 einmal %', v; END IF;

  -- Neue Version fragt erneut; zweimal ohne Reaktion: Einschalten entfaellt
  DELETE FROM agent.advisor_plans WHERE domain = d AND status = 'draft';
  UPDATE agent.advisor_plans SET version = 2, watch_candidates = '[]' WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 5 THEN RAISE EXCEPTION 'FAIL neue Version %', v; END IF;
  FOR v_key IN SELECT x->>'key' FROM jsonb_array_elements(v->'messages'->0->'latches') x LOOP PERFORM core.fn_notify_commit('plan_rollout', v_key); END LOOP;
  UPDATE agent.advisor_plans SET version = 3 WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->'messages'->0->'buttons')::text LIKE '%watch:on%' THEN RAISE EXCEPTION 'FAIL zweimal ohne Reaktion %', v; END IF;

  -- Domain ohne Sync-Pflicht: keine Schritte 0 und 4
  UPDATE core.config SET value = 'false' WHERE category = 'advisor' AND key = 'plan_sync_required';
  UPDATE agent.advisor_plans SET version = 4, synced_at = NULL, watch_candidates = '["x"]' WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::text IS NOT NULL AND (v->>'step')::int IN (0, 4) THEN RAISE EXCEPTION 'FAIL ohne Sync %', v; END IF;

  -- Paket-Schritt: Nachricht ohne Knopf verworfen; dauerhaftes wait endet nach rollout_wait_days
  UPDATE agent.advisor_plans SET version = 5 WHERE id = v_plan;
  -- rollout_fn wirft: neutral
  EXECUTE $f$CREATE FUNCTION core.fn_roll_throw(text, text) RETURNS jsonb LANGUAGE plpgsql AS $b$ BEGIN RAISE EXCEPTION 'kaputt'; END $b$;$f$;
  UPDATE core.advisors SET rollout_fn = 'core.fn_roll_throw' WHERE domain = d;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::text IS NOT NULL AND (v->>'step')::int = 3 THEN RAISE EXCEPTION 'FAIL throw %', v; END IF;
  UPDATE core.advisors SET rollout_fn = 'core.fn_roll_test' WHERE domain = d;
  EXECUTE $f$CREATE FUNCTION core.fn_roll_test(text, text) RETURNS jsonb LANGUAGE sql AS $b$ SELECT '{"wait":true,"messages":[{"msg":[],"buttons":[]}]}'::jsonb $b$;$f$;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 3 OR (v->>'wait')::boolean IS NOT TRUE OR jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL s3 wait %', v; END IF;
  UPDATE core.notification_state SET last_fired_at = now() - interval '8 days' WHERE source = 'plan_rollout' AND key LIKE d || ':%:3wait';
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'wait')::boolean IS TRUE AND (v->>'step')::int = 3 THEN RAISE EXCEPTION 'FAIL s3 Ende %', v; END IF;

  -- per_user: je Person, kein watch:on
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES ('__rollp___planning', 'per_user', 'own_user_only', 'core') ON CONFLICT DO NOTHING;
  INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__rollp__', 'core', '__rollp___planning', 'core.fn_x', TRUE);
  UPDATE core.config SET value = 'true' WHERE category = 'advisor' AND key = 'plan_sync_required';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version) VALUES ('__rollp__', 'erika', 'p', 'active', 1), ('__rollp__', 'lena', 'p', 'active', 1);
  v := core.fn_plan_rollout_next('__rollp__', 'lena');
  IF (v->>'step')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL per_user lena %', v; END IF;
  v := core.fn_plan_rollout_next('__rollp__', 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL per_user erika %', v; END IF;
  UPDATE agent.advisor_plans SET synced_at = now() WHERE domain = '__rollp__';
  v := core.fn_plan_rollout_next('__rollp__', 'erika');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL per_user kein Schluss %', v; END IF;
  -- Entwurf je Person: Lenas offener Entwurf haelt Erikas Uebergabe-Liste nicht an, ihren eigenen Entwurf schon
  UPDATE core.config SET value = '30' WHERE category = 'advisor' AND key = 'rollout_draft_stale_days';
  INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version) VALUES ('__rollp__', 'lena', 'p', 'draft', 2);
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES ('__rollp__', 'core', 'erika', 's', 'other', 'Aufgabe E'), ('__rollp__', 'core', 'lena', 's', 'other', 'Aufgabe L');
  v := core.fn_plan_rollout_next('__rollp__', 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR jsonb_array_length(v->'messages') <> 1 THEN RAISE EXCEPTION 'FAIL per_user fremder Entwurf %', v; END IF;
  v := core.fn_plan_rollout_next('__rollp__', 'lena');
  IF (v->>'wait')::boolean IS NOT TRUE OR jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL per_user eigener Entwurf %', v; END IF;
END $$;
ROLLBACK;
