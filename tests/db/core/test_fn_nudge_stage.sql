-- tests/db/core/test_fn_nudge_stage.sql
-- core.fn_nudge_stage(p): gemeinsamer Stufen-Helfer der Nachfass-Erinnerungen (Einrichten, Beratung).
--   Stufe 1 ab first_days Stillstand, Stufe 2 ab last_days und gap_days nach Stufe 1, danach Ruhe; told-Doppelsperre;
--   Re-Arm bei Fortschritt nach der letzten Stufe (mit Mindestabstand rearm_days); Budget voll / Pause -> unverbraucht;
--   Quellen-Grenze exclusive_sources (eine andere Nachfass-Quelle hat der Person heute schon geschrieben -> heute nichts,
--   unverbraucht); ausserhalb des Erinnerungs-Fensters -> nichts.
-- db_test hat kein seed_data -> Person, Fenster self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  s int;
  base jsonb;
  h int := extract(hour FROM now())::int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- Erinnerungs-Fenster ganztags, damit der Test zu jeder Uhrzeit laeuft (Fall 9 schiebt es weg)
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'general', 'reminders_from', '0'), ('core', 'general', 'reminders_until', '24')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  DELETE FROM core.notification_state WHERE source IN ('t_nudge', 't_other');
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred; DELETE FROM agent.reminder_pause;

  base := jsonb_build_object('source', 't_nudge', 'key_prefix', 'erika:x', 'person_id', 'erika', 'slot', 't_nudge',
    'first_days', 4, 'last_days', 14, 'gap_days', 7, 'rearm_days', 14, 'exclusive_sources', jsonb_build_array('t_other'));

  -- ---------- (1) unter first_days -> nichts; ab first_days -> Stufe 1, Merker gesetzt ----------
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '3 days', 'rearm_since', now() - interval '3 days'));
  IF s IS NOT NULL THEN RAISE EXCEPTION 'FAIL [1 unter first_days]: %', s; END IF;
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS DISTINCT FROM 1 OR NOT core.fn_notify_told('t_nudge', 'erika:x:1') THEN RAISE EXCEPTION 'FAIL [1 Stufe 1]: %', s; END IF;

  -- ---------- (2) gleich nochmal -> nichts (told) ----------
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS NOT NULL THEN RAISE EXCEPTION 'FAIL [2 Doppel]: %', s; END IF;

  -- ---------- (3) Stufe 2: last_days erreicht, aber Stufe 1 erst vor 3 Tagen -> nichts; vor 8 Tagen -> Stufe 2 ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '3 days' WHERE source = 't_nudge' AND key = 'erika:x:1';
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '15 days', 'rearm_since', now() - interval '15 days'));
  IF s IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 gap_days]: %', s; END IF;
  UPDATE core.notification_state SET last_fired_at = now() - interval '8 days' WHERE source = 't_nudge' AND key = 'erika:x:1';
  DELETE FROM core.proactive_budget;
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '15 days', 'rearm_since', now() - interval '15 days'));
  IF s IS DISTINCT FROM 2 THEN RAISE EXCEPTION 'FAIL [3 Stufe 2]: %', s; END IF;

  -- ---------- (4) danach Ruhe; Stufe 2 bleibt wahr, belegt aber keinen Slot ----------
  DELETE FROM core.proactive_budget;
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '40 days', 'rearm_since', now() - interval '40 days'));
  IF s IS NOT NULL OR EXISTS (SELECT 1 FROM core.proactive_budget) THEN RAISE EXCEPTION 'FAIL [4 Ruhe ohne Slot]: %', s; END IF;

  -- ---------- (5) Re-Arm: Fortschritt nach der letzten Stufe, aber die letzte Stufe erst vor 5 Tagen -> keine neue Stufe ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '5 days' WHERE source = 't_nudge' AND key = 'erika:x:2';
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '4 days', 'rearm_since', now() - interval '4 days'));
  IF s IS NOT NULL OR NOT core.fn_notify_told('t_nudge', 'erika:x:1') THEN RAISE EXCEPTION 'FAIL [5 Re-Arm vor Mindestabstand]: %', s; END IF;
  -- letzte Stufe vor 20 Tagen, Fortschritt vor 5 Tagen -> beide Stufen wieder scharf -> Stufe 1
  UPDATE core.notification_state SET last_fired_at = now() - interval '30 days' WHERE source = 't_nudge' AND key = 'erika:x:1';
  UPDATE core.notification_state SET last_fired_at = now() - interval '20 days' WHERE source = 't_nudge' AND key = 'erika:x:2';
  DELETE FROM core.proactive_budget;
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS DISTINCT FROM 1 OR core.fn_notify_told('t_nudge', 'erika:x:2') THEN RAISE EXCEPTION 'FAIL [5 Re-Arm]: %', s; END IF;
  -- rearm_days 0 (Einrichten): Re-Arm sofort
  DELETE FROM core.notification_state WHERE source = 't_nudge';
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES
    ('t_nudge', 'erika:x:1', 'fired', now() - interval '12 days'), ('t_nudge', 'erika:x:2', 'fired', now() - interval '2 days');
  DELETE FROM core.proactive_budget;
  s := core.fn_nudge_stage(base || jsonb_build_object('rearm_days', 0, 'idle_since', now() - interval '5 days', 'rearm_since', now() - interval '1 day'));
  IF s IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [5 rearm_days 0]: %', s; END IF;

  -- ---------- (6) Budget voll -> unverbraucht ----------
  DELETE FROM core.notification_state WHERE source = 't_nudge';
  DELETE FROM core.proactive_budget;
  PERFORM core.fn_proactive_claim('erika', 'x1', 'normal'); PERFORM core.fn_proactive_claim('erika', 'x2', 'normal');
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS NOT NULL OR core.fn_notify_told('t_nudge', 'erika:x:1') THEN RAISE EXCEPTION 'FAIL [6 Budget voll]: %', s; END IF;
  DELETE FROM core.proactive_budget; DELETE FROM core.proactive_deferred;

  -- ---------- (7) Pause -> unverbraucht ----------
  INSERT INTO agent.reminder_pause (person_id, until_date) VALUES ('erika', core.fn_today() + 3);
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS NOT NULL OR core.fn_notify_told('t_nudge', 'erika:x:1') THEN RAISE EXCEPTION 'FAIL [7 Pause]: %', s; END IF;
  DELETE FROM agent.reminder_pause;

  -- ---------- (8) Quellen-Grenze: andere Quelle heute schon an diese Person -> nichts, unverbraucht, kein Slot ----------
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('t_other', 'erika:finance:7:1', 'fired', now());
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS NOT NULL OR core.fn_notify_told('t_nudge', 'erika:x:1') OR EXISTS (SELECT 1 FROM core.proactive_budget) THEN
    RAISE EXCEPTION 'FAIL [8 Quellen-Grenze]: %', s; END IF;
  -- gestern gefeuert oder an eine andere Person -> zaehlt nicht
  UPDATE core.notification_state SET last_fired_at = now() - interval '1 day' WHERE source = 't_other';
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES ('t_other', 'erika_b:1', 'fired', now());
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS DISTINCT FROM 1 THEN RAISE EXCEPTION 'FAIL [8 gestern / andere Person]: %', s; END IF;

  -- ---------- (9) ausserhalb des Erinnerungs-Fensters -> nichts ----------
  DELETE FROM core.notification_state WHERE source = 't_nudge';
  DELETE FROM core.proactive_budget;
  UPDATE core.config SET value = CASE key WHEN 'reminders_from' THEN (CASE WHEN h < 23 THEN h + 1 ELSE 0 END)::text
                                         ELSE (CASE WHEN h < 23 THEN h + 2 ELSE 1 END)::text END
   WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  s := core.fn_nudge_stage(base || jsonb_build_object('idle_since', now() - interval '5 days', 'rearm_since', now() - interval '5 days'));
  IF s IS NOT NULL OR core.fn_notify_told('t_nudge', 'erika:x:1') THEN RAISE EXCEPTION 'FAIL [9 Fenster]: %', s; END IF;

  -- ---------- (10) fehlende Pflichtwerte -> nichts, wirft nie ----------
  UPDATE core.config SET value = CASE key WHEN 'reminders_from' THEN '0' ELSE '24' END WHERE category = 'general' AND key IN ('reminders_from', 'reminders_until');
  IF core.fn_nudge_stage(base - 'idle_since') IS NOT NULL OR core.fn_nudge_stage('{}'::jsonb) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [10 Pflichtwerte]'; END IF;

  RAISE NOTICE 'PASS test_fn_nudge_stage (Schwellen, told, Abstand, Ruhe ohne Slot, Re-Arm mit Mindestabstand, Budget, Pause, Quellen-Grenze, Fenster)';
END $$;

ROLLBACK;
