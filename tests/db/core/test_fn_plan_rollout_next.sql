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
  IF v->'messages'->0->'msg'->0->'params'->>'list' IS DISTINCT FROM '1. Aufgabe A' THEN RAISE EXCEPTION 'FAIL s1 working %', v; END IF;
  IF v->'messages'->0->'msg'->0->'params'->'why'->>'value' IS DISTINCT FROM 'core.handoff.why_rollout_one' THEN RAISE EXCEPTION 'FAIL s1 why %', v; END IF;
  IF v->'messages'->0->'buttons'->0->>'data' IS DISTINCT FROM 'handoff:' || d || ':' || (SELECT min(id) FROM agent.handoff_tasks WHERE domain = d) THEN RAISE EXCEPTION 'FAIL s1 max ohne working %', v; END IF;
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
  -- stilles Warten ohne Frist: auch 30 Tage alte offene Eintraege halten Wert-Waechter und Schluss auf (kein "eingerichtet",
  -- solange etwas offen ist); erst wenn nichts mehr open/working ist, geht es weiter
  UPDATE agent.handoff_tasks SET created_at = now() - interval '30 days' WHERE domain = d;
  UPDATE agent.advisor_plans SET watch_candidates = '["Oelpreis"]' WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 2 OR (v->>'wait')::boolean IS NOT TRUE OR jsonb_array_length(v->'messages') <> 0 THEN
    RAISE EXCEPTION 'FAIL s2 ohne Frist %', v; END IF;
  -- zurueckgestellt und gestrichen halten nicht auf
  UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'tool_missing' WHERE domain = d AND text = 'Aufgabe A';
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'dropped' WHERE domain = d AND text = 'Aufgabe B';
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
  -- Die Liste kaeme je neuer Version einmal neu (Block unten); die Faelle hier pruefen die Schritte danach.
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now() WHERE domain = d AND status IN ('open', 'working');

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

-- Liste nach dem Veroeffentlichen: genau einmal je veroeffentlichter Version, auch wenn dieselbe Liste vorher mitten im
-- Gespraech gezeigt wurde (Merker des Berater-Wegs unter der alten Version).
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__rollv__', 'core', '__rollv___planning', 'core.fn_x', TRUE);
DO $$
DECLARE
  d CONSTANT TEXT := '__rollv__';
  v JSONB;
  v_plan INT;
  v_max INT;
  v_key TEXT;
BEGIN
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, synced_at) VALUES (d, 'p', 'active', 1, now()) RETURNING id INTO v_plan;
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'draft', 2);
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES
    (d, 'core', 'erika', 's', 'other', 'Aufgabe A'), (d, 'core', 'erika', 's', 'other', 'Aufgabe B');
  SELECT max(id) INTO v_max FROM agent.handoff_tasks WHERE domain = d;

  -- mitten im Gespraech: der Berater schickt die Liste (Warnung) und merkt sie
  v := core.fn_handoff_overview_mark(jsonb_build_object('domain', d, 'chat_id', '111', 'max_task_id', v_max));
  IF (v->>'marked')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL P0 Merker %', v; END IF;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL P0 Entwurf sendet %', v; END IF;

  -- (1) veroeffentlicht (v2): Schritt 1 sendet die Liste
  UPDATE agent.advisor_plans SET status = 'superseded' WHERE id = v_plan;
  UPDATE agent.advisor_plans SET status = 'active', synced_at = now() WHERE domain = d AND status = 'draft' RETURNING id INTO v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR jsonb_array_length(v->'messages') <> 1
     OR v->'messages'->0->'buttons'->0->>'data' IS DISTINCT FROM 'handoff:' || d || ':' || v_max THEN RAISE EXCEPTION 'FAIL P0 Live-Fall %', v; END IF;
  v_key := v->'messages'->0->'latch'->>'key';
  IF v_key IS DISTINCT FROM d || ':household:2:handoff:' || v_max THEN RAISE EXCEPTION 'FAIL P0 Schluessel %', v_key; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v_key);

  -- (2) zweiter Aufruf nach dem Festschreiben: keine zweite Liste
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 0 OR (v->>'step')::int IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL P0 einmal %', v; END IF;

  -- (3) neu veroeffentlicht (v3) mit denselben offenen Eintraegen: einmal neu
  UPDATE agent.advisor_plans SET version = 3 WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR jsonb_array_length(v->'messages') <> 1 THEN RAISE EXCEPTION 'FAIL P0 v3 %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v->'messages'->0->'latch'->>'key');

  -- (4) Liste nach dem Veroeffentlichen ueber den Berater-Weg gemerkt (v4): Schritt 1 sendet nicht doppelt
  UPDATE agent.advisor_plans SET version = 4 WHERE id = v_plan;
  PERFORM core.fn_handoff_overview_mark(jsonb_build_object('domain', d, 'chat_id', '111', 'max_task_id', v_max));
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages') <> 0 THEN RAISE EXCEPTION 'FAIL P0 Berater-Weg nach Publish %', v; END IF;
END $$;

-- Korrektur-Schritt (step fix): nach dem Update angebotene Nachhol-Eintraege aus dem Register, einmal je Aufgabe,
-- nie bei offenen Eintraegen oder offenem Entwurf; ohne Vorpruefung, die jetzt durchlaeuft, kein Angebot. Eine erledigte
-- Aufgabe wird nur mit einem nie eingetragenen vereinbarten Aufruf angeboten, nie wegen eines abweichenden Felds.
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__rollf__', 'core', '__rollf___planning', 'core.fn_x', TRUE);
CREATE FUNCTION core.fn_t_fix_check(p jsonb) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE WHEN COALESCE(current_setting('t.fix_mode', true), '') = 'now'
              THEN jsonb_build_object('ok', true, 'call', jsonb_build_object('tool', 'set_x', 'input', '{}'::jsonb))
              ELSE '{"ok":true,"unsupported":true,"blocked_code":"tool_missing"}'::jsonb END $f$;
CREATE FUNCTION core.fn_t_fix_diff(p_task int) RETURNS jsonb LANGUAGE sql AS $f$
  SELECT CASE (SELECT text FROM agent.handoff_tasks WHERE id = p_task)
              WHEN 'geaendert' THEN '[{"field":"day","wanted":1,"current":15,"ref":{"type":"x","id":1}}]'::jsonb
              WHEN 'teil fehlt' THEN '[{"field":"exists","wanted":true,"current":false,"call":{"tool":"set_x","input":{"name":"b"}}}]'::jsonb
              ELSE '[]'::jsonb END $f$;
DO $$
DECLARE
  d CONSTANT TEXT := '__rollf__';
  v JSONB;
  v_def INT;
  v_open INT;
  v_part INT;
BEGIN
  UPDATE core.config SET value = 'false' WHERE category = 'advisor' AND key = 'plan_sync_required';
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, synced_at, interview_state)
  VALUES (d, 'p', 'active', 1, now(), '{"s":{"content":"x"}}');
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, blocked_code)
  VALUES (d, 'core', 'erika', 's', 'other', 'wartet', 'deferred', 'tool_missing') RETURNING id INTO v_def;
  -- ohne Vorpruefung: kein Angebot, deferred haelt den Schluss nicht auf
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'fix' THEN RAISE EXCEPTION 'FAIL fix ohne Vorpruefung %', v; END IF;
  UPDATE core.advisors SET handoff_check_fn = 'core.fn_t_fix_check' WHERE domain = d;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'fix' THEN RAISE EXCEPTION 'FAIL fix geht noch nicht %', v; END IF;
  PERFORM set_config('t.fix_mode', 'now', true);
  -- offener Eintrag: still warten, kein Angebot
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES (d, 'core', 'erika', 's', 'other', 'offen') RETURNING id INTO v_open;
  PERFORM core.fn_notify_commit('plan_rollout', (core.fn_plan_rollout_next(d, 'erika'))->'messages'->0->'latch'->>'key');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' <> '2' OR (v->>'wait')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL fix bei offenem Eintrag %', v; END IF;
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'dropped' WHERE id = v_open;
  -- offener Entwurf: kein Angebot
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'draft', 2);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'fix' THEN RAISE EXCEPTION 'FAIL fix bei Entwurf %', v; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = d AND status = 'draft';
  -- jetzt: ein Angebot mit Merker je Aufgabe
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'fix' OR v->'messages'->0->'msg'->0->>'value' <> 'core.rollout.fix_offer_one'
     OR v->'messages'->0->'buttons'->0->>'text_key' <> 'core.handoff.btn_go'
     OR v->'messages'->0->'buttons'->0->>'data' <> 'handoff:' || d || ':' || v_def || ':fix'
     OR v->'messages'->0->'latches'->0->>'key' <> d || ':household:1:fix:' || v_def THEN RAISE EXCEPTION 'FAIL fix Angebot %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v->'messages'->0->'latches'->0->>'key');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'fix' THEN RAISE EXCEPTION 'FAIL fix zweimal %', v; END IF;
  -- zwei neue Aufgaben, je eigener Merker; die Zahl nennt alles, was der Knopf beansprucht (auch die frueher angebotene)
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, blocked_code)
  VALUES (d, 'core', 'erika', 's', 'other', 'wartet 2', 'deferred', 'tool_missing'), (d, 'core', 'erika', 's', 'other', 'wartet 3', 'deferred', 'tool_missing');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'fix' OR v->'messages'->0->'msg'->0->>'value' <> 'core.rollout.fix_offer'
     OR (v->'messages'->0->'msg'->0->'params'->>'n')::int <> 3 OR jsonb_array_length(v->'messages'->0->'latches') <> 2 THEN
    RAISE EXCEPTION 'FAIL fix zwei %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', l->>'key') FROM jsonb_array_elements(v->'messages'->0->'latches') l;

  -- wie vereinbart eingetragen, spaeter vom Nutzer geaendert (Unterschied nur in einem Feld): nie ein Nachhol-Angebot,
  -- auch wenn die Vorpruefung einen Aufruf liefert
  UPDATE core.advisors SET handoff_diff_fn = 'core.fn_t_fix_diff' WHERE domain = d;
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at, close_reason, wanted, entered_refs)
  VALUES (d, 'core', 'erika', 's', 'other', 'geaendert', 'done', now(), now(), 'entered', '{"tool":"set_x","input":{"day":1}}', '[{"type":"x","id":1}]');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS NOT DISTINCT FROM 'fix' THEN RAISE EXCEPTION 'FAIL fix fuer eine eigene Aenderung %', v; END IF;
  -- ein vereinbarter Aufruf, der nie eingetragen wurde (Unterschied mit call): Angebot, die Zahl nennt nur Nachholbares
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at, close_reason, wanted, entered_refs)
  VALUES (d, 'core', 'erika', 's', 'other', 'teil fehlt', 'done', now(), now(), 'entered',
          '[{"tool":"set_x","input":{"name":"a"}},{"tool":"set_x","input":{"name":"b"}}]', '[{"type":"x","id":2,"call":0}]') RETURNING id INTO v_part;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'fix' OR (v->'messages'->0->'msg'->0->'params'->>'n')::int IS DISTINCT FROM 4
     OR jsonb_array_length(v->'messages'->0->'latches') <> 1
     OR v->'messages'->0->'latches'->0->>'key' <> d || ':household:1:fix:' || v_part
     OR v->'messages'->0->'buttons'->0->>'data' <> 'handoff:' || d || ':' || v_part || ':fix' THEN RAISE EXCEPTION 'FAIL fix fehlender Teil %', v; END IF;
END $$;

-- Folge-Zeile der Liste (core.advisors.entry_effects_fn): nur mit Hinweisen der Klasse entry (accounts > 0), eigener Satz fuer 1;
-- fehlende oder werfende Paket-fn -> keine Zeile.
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step) VALUES ('__rolle__', 'core', '__rolle___planning', 'core.fn_x', TRUE);
CREATE FUNCTION core.fn_t_effects(p_domain text) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
  IF current_setting('t.eff', true) = 'throw' THEN RAISE EXCEPTION 'kaputt'; END IF;
  RETURN jsonb_build_object('accounts', COALESCE(NULLIF(current_setting('t.eff', true), ''), '0')::int);
END $f$;
DO $$
DECLARE
  d CONSTANT TEXT := '__rolle__';
  v JSONB;
BEGIN
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, synced_at) VALUES (d, 'p', 'active', 1, now());
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES (d, 'core', 'erika', 's', 'other', 'Aufgabe');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR jsonb_array_length(v->'messages'->0->'msg') <> 1 THEN RAISE EXCEPTION 'FAIL eff ohne fn %', v; END IF;
  PERFORM core.fn_notify_resolve('plan_rollout', v->'messages'->0->'latch'->>'key');
  UPDATE core.advisors SET entry_effects_fn = 'core.fn_t_effects' WHERE domain = d;
  PERFORM set_config('t.eff', '2', true);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages'->0->'msg') <> 2 OR v->'messages'->0->'msg'->1->>'value' <> 'core.handoff.effect'
     OR (v->'messages'->0->'msg'->1->'params'->>'n')::int <> 2 THEN RAISE EXCEPTION 'FAIL eff 2 %', v; END IF;
  PERFORM core.fn_notify_resolve('plan_rollout', v->'messages'->0->'latch'->>'key');
  PERFORM set_config('t.eff', '1', true);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->'messages'->0->'msg'->1->>'value' IS DISTINCT FROM 'core.handoff.effect_one' THEN RAISE EXCEPTION 'FAIL eff 1 %', v; END IF;
  PERFORM core.fn_notify_resolve('plan_rollout', v->'messages'->0->'latch'->>'key');
  PERFORM set_config('t.eff', '0', true);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF jsonb_array_length(v->'messages'->0->'msg') <> 1 THEN RAISE EXCEPTION 'FAIL eff 0 %', v; END IF;
  PERFORM core.fn_notify_resolve('plan_rollout', v->'messages'->0->'latch'->>'key');
  PERFORM set_config('t.eff', 'throw', true);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF (v->>'step')::int IS DISTINCT FROM 1 OR jsonb_array_length(v->'messages'->0->'msg') <> 1 THEN RAISE EXCEPTION 'FAIL eff wirft %', v; END IF;
END $$;

-- Pruef-Schritt (step check): Altbestand, der vor der Provenienz erledigt wurde (Register row_kind legacy, status done),
-- geht einmal je Aufgabe ueber [Eintraege pruefen] an den Berater; der Merker haengt nicht an der Version (eine neue
-- Version bietet dieselbe Aufgabe nicht wieder an). Nie bei offenem Eintrag oder offenem Entwurf, nie fuer gestrichene
-- Aufgaben oder solche mit Folge-Aufgabe; der Korrektur-Schritt (fix) geht vor.
INSERT INTO core.advisors (domain, package, plan_context, review_fn, plan_step, advisor_agent)
VALUES ('__rollk__', 'core', '__rollk___planning', 'core.fn_x', TRUE, 'agent.x_advisor');
DO $$
DECLARE
  d CONSTANT TEXT := '__rollk__';
  v JSONB;
  v_old INT;
  v_open INT;
  v_plan INT;
BEGIN
  UPDATE core.config SET value = 'false' WHERE category = 'advisor' AND key = 'plan_sync_required';
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version, synced_at, interview_state)
  VALUES (d, 'p', 'active', 1, now(), '{"s":{"content":"x"}}') RETURNING id INTO v_plan;
  -- gestrichen ohne Provenienz: kein Pruef-Angebot (ohne Vorpruefung auch kein fix)
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'alt gestrichen', 'cancelled', now());
  -- Abschnitt nicht mehr im Plan: kein Angebot
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 'weg', 'other', 'alt woanders', 'done', now());
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'check' THEN RAISE EXCEPTION 'FAIL check ohne Kandidat %', v; END IF;

  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'alt erledigt', 'done', now()) RETURNING id INTO v_old;
  -- offener Eintrag: still warten
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text) VALUES (d, 'core', 'erika', 's', 'other', 'offen') RETURNING id INTO v_open;
  PERFORM core.fn_notify_commit('plan_rollout', (core.fn_plan_rollout_next(d, 'erika'))->'messages'->0->'latch'->>'key');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' <> '2' THEN RAISE EXCEPTION 'FAIL check bei offenem Eintrag %', v; END IF;
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'dropped' WHERE id = v_open;
  -- offener Entwurf: kein Angebot
  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'draft', 2);
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'check' THEN RAISE EXCEPTION 'FAIL check bei Entwurf %', v; END IF;
  DELETE FROM agent.advisor_plans WHERE domain = d AND status = 'draft';

  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'check' OR v->'messages'->0->'msg'->0->>'value' <> 'core.rollout.check_offer_one'
     OR v->'messages'->0->'buttons'->0->>'text_key' <> 'core.rollout.btn_check'
     OR v->'messages'->0->'buttons'->0->>'data' <> 'plan:check:' || d
     OR v->'messages'->0->>'memory_agent' <> 'agent.x_advisor'
     OR v->'messages'->0->'latches'->0->>'key' <> d || ':household:check:' || v_old
     OR jsonb_array_length(v->'messages'->0->'latches') <> 1 THEN RAISE EXCEPTION 'FAIL check Angebot %', v; END IF;
  PERFORM core.fn_notify_commit('plan_rollout', v->'messages'->0->'latches'->0->>'key');
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'check' THEN RAISE EXCEPTION 'FAIL check zweimal %', v; END IF;
  -- neue Version: dieselbe Aufgabe nicht wieder
  UPDATE agent.advisor_plans SET version = 2 WHERE id = v_plan;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' = 'check' THEN RAISE EXCEPTION 'FAIL check neue Version %', v; END IF;

  -- zwei weitere: eine Nachricht, n = 2, je Aufgabe ein Merker; eine mit Folge-Aufgabe zaehlt nicht
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  VALUES (d, 'core', 'erika', 's', 'other', 'alt 2', 'done', now()), (d, 'core', 'erika', 's', 'other', 'alt 3', 'done', now()),
         (d, 'core', 'erika', 's', 'other', 'alt 4', 'done', now());
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, follows_task_id)
  SELECT d, 'core', 'erika', 's', 'other', 'Korrektur', max(id) FROM agent.handoff_tasks WHERE domain = d AND text = 'alt 4' RETURNING id INTO v_open;
  UPDATE agent.handoff_tasks SET status = 'cancelled', closed_at = now(), close_reason = 'dropped' WHERE id = v_open;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'check' OR v->'messages'->0->'msg'->0->>'value' <> 'core.rollout.check_offer'
     OR (v->'messages'->0->'msg'->0->'params'->>'n')::int <> 2 OR jsonb_array_length(v->'messages'->0->'latches') <> 2
     OR v->'messages'->0->'buttons'->0->>'data' <> 'plan:check:' || d THEN
    RAISE EXCEPTION 'FAIL check zwei %', v; END IF;
  FOR v IN SELECT x FROM jsonb_array_elements(v->'messages'->0->'latches') x LOOP PERFORM core.fn_notify_commit('plan_rollout', v->>'key'); END LOOP;
  -- hoechstens 20 je Angebot (so viele nimmt der Knopf mit); der Rest bleibt frei fuer das naechste Angebot
  INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status, closed_at)
  SELECT d, 'core', 'erika', 's', 'other', 'viel ' || g, 'done', now() FROM generate_series(1, 22) g;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'check' OR (v->'messages'->0->'msg'->0->'params'->>'n')::int <> 20 OR jsonb_array_length(v->'messages'->0->'latches') <> 20 THEN
    RAISE EXCEPTION 'FAIL check 20 %', v; END IF;
  FOR v IN SELECT x FROM jsonb_array_elements(v->'messages'->0->'latches') x LOOP PERFORM core.fn_notify_commit('plan_rollout', v->>'key'); END LOOP;
  v := core.fn_plan_rollout_next(d, 'erika');
  IF v->>'step' IS DISTINCT FROM 'check' OR (v->'messages'->0->'msg'->0->'params'->>'n')::int <> 2 THEN RAISE EXCEPTION 'FAIL check Rest %', v; END IF;
END $$;
ROLLBACK;
