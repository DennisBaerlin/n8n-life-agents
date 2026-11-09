-- tests/db/core/test_fn_plan_sync.sql
-- core.fn_plan_sync: Erinnerungen eines Plans in einer Transaktion abgleichen (Regel-Tabelle a bis h, retire, declined,
-- Ablehnungen als Daten, Rollback bei Teil-Write, effective-Datum, deadline aus Config, kein Versionswechsel).
BEGIN;
INSERT INTO core.config (package, category, key, value) VALUES ('core', 'advisor', 'reminder_deadline_warn_days', '7')
ON CONFLICT (category, key) DO UPDATE SET value = excluded.value;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'sync fixture', NULL, 'lazy', E'## fam', jsonb_build_object('managed_by','agent','protected', TRUE,
  'facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
    jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel','role','partner','birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

DO $$
DECLARE
  d CONSTANT TEXT := '__test_sync__';
  v JSONB;
  v_plan INT;
  v_cnt INT;
  r agent.monitor_triggers%ROWTYPE;
  v_t1 DATE := core.fn_today() + 30;
  v_t2 DATE := core.fn_today() + 60;
BEGIN
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', '[]'));
  IF v->>'code' <> 'no_active_plan' THEN RAISE EXCEPTION 'FAIL no_active_plan %', v; END IF;

  INSERT INTO agent.advisor_plans (domain, plan_name, status, version) VALUES (d, 'p', 'active', 4) RETURNING id INTO v_plan;

  -- h: anlegen; deadline setzt warn aus Config, ein Modell-Wert wird ignoriert; kein Echo
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(
    jsonb_build_object('label', 'Rente pruefen', 'remind_on', v_t1, 'action_note', 'n'),
    jsonb_build_object('label', 'Frist Bauspar', 'remind_on', v_t1, 'deadline', true, 'warn_days_before', 99))));
  IF (v->>'ok')::boolean IS NOT TRUE OR jsonb_array_length(v->'created') <> 2 OR (v->>'changes')::int <> 2 THEN RAISE EXCEPTION 'FAIL create %', v; END IF;
  IF (v->>'plan_id')::int <> v_plan OR v->>'synced_at' IS NULL THEN RAISE EXCEPTION 'FAIL handles %', v; END IF;
  IF jsonb_array_length(v->'card_lines') <> 2 THEN RAISE EXCEPTION 'FAIL card_lines %', v; END IF;
  IF (v->'created'->0->>'trigger_id') IS NULL OR (v->'created'->0->>'due_date')::date <> v_t1 THEN RAISE EXCEPTION 'FAIL created row %', v; END IF;
  SELECT * INTO r FROM agent.monitor_triggers WHERE domain = d AND label = 'Rente pruefen';
  IF r.due_date <> v_t1 OR r.warn_days_before <> 0 OR r.check_interval <> interval '1 day' OR r.acquisition_method <> 'none' THEN RAISE EXCEPTION 'FAIL row %', r; END IF;
  SELECT * INTO r FROM agent.monitor_triggers WHERE domain = d AND label = 'Frist Bauspar';
  IF r.warn_days_before <> 7 THEN RAISE EXCEPTION 'FAIL deadline warn %', r.warn_days_before; END IF;

  -- Sync aendert die Version nicht, stempelt synced_at
  IF (SELECT version FROM agent.advisor_plans WHERE id = v_plan) <> 4 OR (SELECT synced_at FROM agent.advisor_plans WHERE id = v_plan) IS NULL
    THEN RAISE EXCEPTION 'FAIL version/synced_at'; END IF;

  -- a: gleiches Datum entfaellt, auch Name anders geschrieben
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', ' rente PRUEFEN ', 'remind_on', v_t1))));
  IF v->'skipped'->0->>'reason' <> 'existing' OR (v->>'changes')::int <> 0 OR jsonb_array_length(v->'card_lines') <> 0 THEN RAISE EXCEPTION 'FAIL a %', v; END IF;

  -- a: fired mit vergangenem gleichem Datum entfaellt ohne invalid_date
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, status, fired_at)
  VALUES (d, 'Alt gefeuert', 'date', core.fn_today() - 5, interval '1 day', 'fired', now());
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Alt gefeuert', 'remind_on', core.fn_today() - 5))));
  IF v->'skipped'->0->>'reason' <> 'existing' THEN RAISE EXCEPTION 'FAIL a fired past %', v; END IF;

  -- b: anderes Datum verschiebt, fired wird scharf, deadline zieht warn mit
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Alt gefeuert', 'remind_on', v_t2, 'deadline', true))));
  IF jsonb_array_length(v->'moved') <> 1 OR (v->>'changes')::int <> 1 THEN RAISE EXCEPTION 'FAIL b %', v; END IF;
  SELECT * INTO r FROM agent.monitor_triggers WHERE domain = d AND label = 'Alt gefeuert';
  IF r.status <> 'armed' OR r.due_date <> v_t2 OR r.fired_at IS NOT NULL OR r.warn_days_before <> 7 THEN RAISE EXCEPTION 'FAIL b row %', r; END IF;

  -- nur deadline geaendert zaehlt nicht als Aenderung
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Alt gefeuert', 'remind_on', v_t2))));
  IF (v->>'changes')::int <> 0 THEN RAISE EXCEPTION 'FAIL deadline only %', v; END IF;

  -- c: vom Nutzer abgeschaltet entfaellt; c2: vom Plan weggeraeumt wird wieder scharf; Nutzer-Aenderung loescht Stempel
  PERFORM agent.fn_set_monitor_trigger(jsonb_build_object('label','Rente pruefen','domain',d,'status','disabled'));
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Rente pruefen', 'remind_on', v_t2))));
  IF v->'skipped'->0->>'reason' <> 'disabled' THEN RAISE EXCEPTION 'FAIL c %', v; END IF;
  PERFORM agent.fn_set_monitor_trigger(jsonb_build_object('label','Rente pruefen','domain',d,'status','armed'));

  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'retire', jsonb_build_array(jsonb_build_object('label', 'Rente pruefen'))));
  IF jsonb_array_length(v->'retired') <> 1 OR (v->>'changes')::int <> 1 OR jsonb_array_length(v->'card_lines') <> 1 THEN RAISE EXCEPTION 'FAIL retire %', v; END IF;
  SELECT * INTO r FROM agent.monitor_triggers WHERE domain = d AND label = 'Rente pruefen';
  IF r.status <> 'disabled' OR r.retired_by_plan_at IS NULL THEN RAISE EXCEPTION 'FAIL retire row %', r; END IF;
  -- schon disabled: No-op
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'retire', jsonb_build_array(jsonb_build_object('label', 'Rente pruefen'))));
  IF (v->>'changes')::int <> 0 THEN RAISE EXCEPTION 'FAIL retire noop %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Rente pruefen', 'remind_on', v_t2))));
  IF jsonb_array_length(v->'moved') <> 1 THEN RAISE EXCEPTION 'FAIL c2 %', v; END IF;
  SELECT * INTO r FROM agent.monitor_triggers WHERE domain = d AND label = 'Rente pruefen';
  IF r.status <> 'armed' OR r.due_date <> v_t2 OR r.retired_by_plan_at IS NOT NULL THEN RAISE EXCEPTION 'FAIL c2 row %', r; END IF;

  -- d: andere Art; e: general
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec, comparator, threshold_value, expected_unit, check_interval)
  VALUES (d, 'Andere Art', 'threshold', 'sql', '{"query":"SELECT 1"}', 'gte', 1, 'x', interval '1 day');
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval) VALUES ('general', 'Allgemein da', 'date', v_t1, interval '1 day');
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(
    jsonb_build_object('label', 'Andere Art', 'remind_on', v_t1), jsonb_build_object('label', 'Allgemein da', 'remind_on', v_t1))));
  IF v->'skipped'->0->>'reason' <> 'other_type' OR v->'skipped'->1->>'reason' <> 'exists_general' THEN RAISE EXCEPTION 'FAIL d/e %', v; END IF;

  -- declined: neu zaehlt und steht auf der Karte, bekannt nicht; f entfaellt; g force legt an
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'declined', jsonb_build_array(jsonb_build_object('label', 'Nein danke', 'remind_on', v_t1))));
  IF (v->>'changes')::int <> 1 OR jsonb_array_length(v->'card_lines') <> 1 THEN RAISE EXCEPTION 'FAIL declined neu %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'declined', jsonb_build_array(jsonb_build_object('label', 'NEIN danke'))));
  IF (v->>'changes')::int <> 0 THEN RAISE EXCEPTION 'FAIL declined bekannt %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Nein danke', 'remind_on', v_t1))));
  IF v->'skipped'->0->>'reason' <> 'declined' THEN RAISE EXCEPTION 'FAIL f %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label', 'Nein danke', 'remind_on', v_t1, 'force', true))));
  IF jsonb_array_length(v->'created') <> 1 OR EXISTS (SELECT 1 FROM agent.plan_reminder_declines WHERE domain = d) THEN RAISE EXCEPTION 'FAIL g %', v; END IF;

  -- retire: Schutz und Unbekanntes
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'retire', jsonb_build_array(jsonb_build_object('label', 'Gibt es nicht'))));
  IF v->>'code' <> 'retire_unknown' THEN RAISE EXCEPTION 'FAIL retire_unknown %', v; END IF;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, due_date, check_interval, origin) VALUES (d, 'Kern', 'date', v_t1, interval '1 day', 'core');
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'retire', jsonb_build_array(jsonb_build_object('label', 'Kern'))));
  IF v->>'code' <> 'retire_protected' THEN RAISE EXCEPTION 'FAIL retire_protected %', v; END IF;

  -- Ablehnungen als Daten, Nummer in reason, kein Write
  SELECT count(*) INTO v_cnt FROM agent.monitor_triggers WHERE domain = d;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','x','remind_on',v_t1), jsonb_build_object('label','X ','remind_on',v_t1))));
  IF v->>'code' <> 'duplicate_reminder' THEN RAISE EXCEPTION 'FAIL duplicate %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','x','remind_on',v_t1)), 'retire', jsonb_build_array(jsonb_build_object('label','X'))));
  IF v->>'code' <> 'sync_conflict' THEN RAISE EXCEPTION 'FAIL conflict retire %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','x','remind_on',v_t1)), 'declined', jsonb_build_array(jsonb_build_object('label','X'))));
  IF v->>'code' <> 'sync_conflict' THEN RAISE EXCEPTION 'FAIL conflict declined %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', (SELECT jsonb_agg(jsonb_build_object('label','l'||g,'remind_on',v_t1)) FROM generate_series(1,31) g)));
  IF v->>'code' <> 'too_many_reminders' THEN RAISE EXCEPTION 'FAIL too_many %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','','remind_on',v_t1))));
  IF v->>'code' <> 'invalid_reminders' OR v->>'reason' NOT LIKE '%#1%' THEN RAISE EXCEPTION 'FAIL invalid %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','a','remind_on',v_t1), jsonb_build_object('label','b','remind_on','naechstes Jahr'))));
  IF v->>'code' <> 'invalid_date' OR v->>'reason' NOT LIKE '%#2%' THEN RAISE EXCEPTION 'FAIL unlesbar %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','neu vergangen','remind_on',core.fn_today()-1))));
  IF v->>'code' <> 'invalid_date' THEN RAISE EXCEPTION 'FAIL Vergangenheit %', v; END IF;
  IF (SELECT count(*) FROM agent.monitor_triggers WHERE domain = d) <> v_cnt THEN RAISE EXCEPTION 'FAIL Ablehnung schrieb'; END IF;

  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'declined', jsonb_build_array(jsonb_build_object('label', 'Falsches Datum', 'remind_on', '2027-13-45'))));
  IF v->>'code' IS DISTINCT FROM 'invalid_date' THEN RAISE EXCEPTION 'FAIL declined Datum %', v; END IF;

  -- JSON-String und leerer String
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', '', 'watch_candidates', '["Oelpreis"]'));
  IF (v->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL string %', v; END IF;
  IF (SELECT watch_candidates FROM agent.advisor_plans WHERE id = v_plan) <> '["Oelpreis"]'::jsonb THEN RAISE EXCEPTION 'FAIL watch gespeichert'; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'watch_candidates', (SELECT jsonb_agg('w'||g) FROM generate_series(1,11) g)));
  IF v->>'code' <> 'invalid_reminders' THEN RAISE EXCEPTION 'FAIL watch Grenze %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'watch_candidates', jsonb_build_array(repeat('x',121))));
  IF v->>'code' <> 'invalid_reminders' THEN RAISE EXCEPTION 'FAIL watch Laenge %', v; END IF;

  -- effective: Probelauf gestern, Write heute legt mit heutigem Datum an
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders_checked_on', core.fn_today() - 1, 'reminders', jsonb_build_array(jsonb_build_object('label','Ueber Mitternacht','remind_on',core.fn_today() - 1))));
  IF (v->>'ok')::boolean IS NOT TRUE OR (v->'created'->0->>'due_date')::date <> core.fn_today() THEN RAISE EXCEPTION 'FAIL effective %', v; END IF;
  IF (v->'effective'->>'reminders_checked_on')::date <> core.fn_today() - 1 THEN RAISE EXCEPTION 'FAIL effective Feld %', v; END IF;
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', '[]'));
  IF (v->'effective'->>'reminders_checked_on')::date <> core.fn_today() THEN RAISE EXCEPTION 'FAIL effective Default %', v; END IF;

  -- Probelauf hinterlaesst nichts
  v := core.fn_dry_run('core.fn_plan_sync(jsonb)'::regprocedure, jsonb_build_object('domain', d, 'reminders', jsonb_build_array(jsonb_build_object('label','Nur Probe','remind_on',v_t1))));
  IF (v->>'changes')::int <> 1 OR EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE domain = d AND label = 'Nur Probe') THEN RAISE EXCEPTION 'FAIL dry run %', v; END IF;

  -- Mitglied: abgelehnt
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'chat_id', '222', 'reminders', '[]'));
  IF (v->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL member %', v; END IF;

  -- Teil-Write: zweiter Eintrag scheitert im Write -> nichts bleibt, sync_stale
  CREATE FUNCTION pg_temp.boom() RETURNS trigger LANGUAGE plpgsql AS $f$ BEGIN
    IF NEW.label = 'Spaet belegt' THEN RAISE unique_violation; END IF; RETURN NEW; END $f$;
  CREATE TRIGGER zz_boom BEFORE INSERT ON agent.monitor_triggers FOR EACH ROW EXECUTE FUNCTION pg_temp.boom();
  v := core.fn_plan_sync(jsonb_build_object('domain', d, 'reminders', jsonb_build_array(
    jsonb_build_object('label','Erster bleibt nicht','remind_on',v_t1), jsonb_build_object('label','Spaet belegt','remind_on',v_t1))));
  DROP TRIGGER zz_boom ON agent.monitor_triggers;
  IF v->>'code' <> 'sync_stale' OR EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE domain = d AND label = 'Erster bleibt nicht')
    THEN RAISE EXCEPTION 'FAIL sync_stale %', v; END IF;
END $$;
ROLLBACK;
