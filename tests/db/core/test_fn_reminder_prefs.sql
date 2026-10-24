-- tests/db/core/test_fn_reminder_prefs.sql
-- Roter Faden: Erinnerungs-Einstellung je Person (agent.reminder_prefs) ueber der Registry core.cron_labels.
--   core.fn_reminder_allowed(key, person) = Notschalter cron_enable UND (Personen-Zeile oder Registry-Default);
--     Haushalts-Keys (scope household) = nur der Notschalter; unbekannter Key = false.
--   core.fn_set_reminder_pref(p)  = Person aus chat_id (nie LLM), nur scope='person'-Keys, Upsert.
--   core.fn_handle_reminder_cb(p) = Registry-Handler 'rem' (member_permeable): rem:on|off:<key> -> eigene Einstellung.
--   core.fn_set_cron_enable lehnt scope='person' ab (ein alter Knopf schaltet nie den Notschalter fuer alle).
-- db_test hat KEIN seed_data -> family + Registry-Zeilen self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE r JSONB; v_cnt int;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'reminder_prefs fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__rp_owner__','first_name','RP','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7201,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__rp_partner__','first_name','RP','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7202,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES
    ('zz_rp_person_on', 'core', 'person', true),
    ('zz_rp_person_off', 'core', 'person', false),
    ('zz_rp_house', 'core', 'household', true)
  ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope, default_enabled = excluded.default_enabled;
  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'cron_enable', 'zz_rp_person_on', 'true'),
    ('core', 'cron_enable', 'zz_rp_person_off', 'true'),
    ('core', 'cron_enable', 'zz_rp_house', 'true')
  ON CONFLICT DO NOTHING;

  -- ---------- 1) Defaults ohne Zeile ----------
  IF core.fn_reminder_allowed('zz_rp_person_on', '__rp_partner__') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1a Default an -> true]'; END IF;
  IF core.fn_reminder_allowed('zz_rp_person_off', '__rp_partner__') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1b Default aus -> false]'; END IF;
  IF core.fn_reminder_allowed('zz_rp_house', '__rp_partner__') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [1c Haushalt-Key = nur Notschalter]'; END IF;
  IF core.fn_reminder_allowed('zz_rp_unknown', '__rp_partner__') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [1d unbekannter Key -> false]'; END IF;

  -- ---------- 2) Mitglied schaltet seine Nachfass-Erinnerung per Knopf ab ----------
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rp_person_on","chat_id":"7202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'toast' IS NULL THEN
    RAISE EXCEPTION 'FAIL [2 rem:off Mitglied -> ok + toast]: %', r; END IF;
  IF core.fn_reminder_allowed('zz_rp_person_on', '__rp_partner__') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [2 nach rem:off -> false]'; END IF;
  IF core.fn_reminder_allowed('zz_rp_person_on', '__rp_owner__') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [2 Owner unberuehrt -> true]'; END IF;
  SELECT count(*) INTO v_cnt FROM agent.reminder_prefs WHERE person_id = '__rp_partner__' AND cron_key = 'zz_rp_person_on' AND NOT enabled;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [2 Zeile erwartet]'; END IF;

  -- ---------- 3) wieder an (idempotent upsert) ----------
  r := core.fn_handle_reminder_cb('{"data":"rem:on:zz_rp_person_on","chat_id":"7202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR core.fn_reminder_allowed('zz_rp_person_on', '__rp_partner__') IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [3 rem:on -> true]: %', r; END IF;

  -- ---------- 4) Notschalter aus gewinnt ueber die Person ----------
  UPDATE core.config SET value = 'false' WHERE category = 'cron_enable' AND key = 'zz_rp_person_on';
  IF core.fn_reminder_allowed('zz_rp_person_on', '__rp_partner__') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [4 Notschalter aus -> false]'; END IF;
  UPDATE core.config SET value = 'true' WHERE category = 'cron_enable' AND key = 'zz_rp_person_on';

  -- ---------- 5) Haushalts-Key / unbekannter Key / kaputtes Verb -> abgelehnt, kein Write ----------
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rp_house","chat_id":"7202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR r->>'toast' IS NULL THEN RAISE EXCEPTION 'FAIL [5a Haushalt-Key -> ok:false + toast]: %', r; END IF;
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rp_unknown","chat_id":"7202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5b unbekannt -> ok:false]: %', r; END IF;
  r := core.fn_handle_reminder_cb('{"data":"rem:maybe:zz_rp_person_on","chat_id":"7202","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5c Verb -> ok:false]: %', r; END IF;
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rp_person_on","chat_id":"999999","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5d unaufgeloest -> ok:false]: %', r; END IF;
  SELECT count(*) INTO v_cnt FROM agent.reminder_prefs WHERE cron_key IN ('zz_rp_house', 'zz_rp_unknown');
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [5 kein Write erwartet]'; END IF;

  -- ---------- 6) fn_set_cron_enable: person-Key -> abgelehnt, Haushalt-Key geht ----------
  r := core.fn_set_cron_enable('{"key":"zz_rp_person_on","enabled":false}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6a person-Key ueber fn_set_cron_enable -> ok:false]: %', r; END IF;
  IF core.fn_config_get('core', 'cron_enable', 'zz_rp_person_on') <> 'true' THEN
    RAISE EXCEPTION 'FAIL [6a Notschalter darf sich nicht bewegen]'; END IF;
  r := core.fn_set_cron_enable('{"key":"zz_rp_house","enabled":false}');
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [6b Haushalt-Key -> ok]: %', r; END IF;

  -- ---------- 7) Person entfernt -> Einstellung per CASCADE weg ----------
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rp_person_on","chat_id":"7202","chat_type":"private"}');
  DELETE FROM agent.persons WHERE person_id = '__rp_partner__';
  SELECT count(*) INTO v_cnt FROM agent.reminder_prefs WHERE person_id = '__rp_partner__';
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL [7 CASCADE erwartet]'; END IF;

  RAISE NOTICE 'PASS test_fn_reminder_prefs (Default/Override/Notschalter, rem:-Handler, fn_set_cron_enable-Sperre, CASCADE)';
END $$;

-- ---------- Paket B (/reminders): Owner schaltet Haushalts-Reminder per rem:, Pflicht-Reminder sind gesperrt,
-- Menue-Knoepfe (Suffix :m) melden route 'reminders' (der Orchestrator sendet das Menue neu). ----------
DO $$
DECLARE r JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'reminder_prefs B fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__rb_owner__','first_name','RB','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7211,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__rb_partner__','first_name','RB','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7212,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled, mandatory) VALUES
    ('zz_rb_house', 'core', 'household', true, false),
    ('zz_rb_person', 'core', 'person', true, false),
    ('zz_rb_must', 'core', 'household', true, true)
  ON CONFLICT (cron_key) DO UPDATE SET scope = excluded.scope, mandatory = excluded.mandatory;
  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'cron_enable', 'zz_rb_house', 'true'), ('core', 'cron_enable', 'zz_rb_person', 'true'),
    ('core', 'cron_enable', 'zz_rb_must', 'true')
  ON CONFLICT (category, key) DO UPDATE SET value = 'true';

  -- 8a) Owner schaltet Haushalts-Reminder aus/ein ueber rem: (Menue oder Karte)
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rb_house","chat_id":"7211","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR core.fn_config_get('core', 'cron_enable', 'zz_rb_house') <> 'false' THEN
    RAISE EXCEPTION 'FAIL [8a Owner rem:off Haushalt -> cron_enable false]: %', r; END IF;
  IF r ? 'route' THEN RAISE EXCEPTION 'FAIL [8a Karten-Knopf ohne :m -> keine route]: %', r; END IF;
  r := core.fn_handle_reminder_cb('{"data":"rem:on:zz_rb_house:m","chat_id":"7211","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'reminders' OR core.fn_config_get('core', 'cron_enable', 'zz_rb_house') <> 'true' THEN
    RAISE EXCEPTION 'FAIL [8a Owner rem:on:..:m -> true + route reminders]: %', r; END IF;

  -- 8b) Mitglied darf Haushalts-Reminder NICHT schalten
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rb_house:m","chat_id":"7212","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE OR core.fn_config_get('core', 'cron_enable', 'zz_rb_house') <> 'true' THEN
    RAISE EXCEPTION 'FAIL [8b Mitglied Haushalt -> abgelehnt, unveraendert]: %', r; END IF;

  -- 8c) Pflicht-Reminder: weder per rem: noch per fn_set_cron_enable schaltbar
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rb_must:m","chat_id":"7211","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [8c mandatory per rem: -> abgelehnt]: %', r; END IF;
  r := core.fn_set_cron_enable('{"key":"zz_rb_must","enabled":false}');
  IF (r->>'ok')::boolean IS NOT FALSE OR core.fn_config_get('core', 'cron_enable', 'zz_rb_must') <> 'true' THEN
    RAISE EXCEPTION 'FAIL [8c mandatory per fn_set_cron_enable -> abgelehnt]: %', r; END IF;

  -- 8d) Person-Reminder aus dem Menue: eigene Einstellung + route
  r := core.fn_handle_reminder_cb('{"data":"rem:off:zz_rb_person:m","chat_id":"7212","chat_type":"private"}');
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'route' <> 'reminders'
     OR core.fn_reminder_allowed('zz_rb_person', '__rb_partner__') IS NOT FALSE THEN
    RAISE EXCEPTION 'FAIL [8d Mitglied Person-Reminder aus dem Menue]: %', r; END IF;

  -- 8e) CHECK: Pflicht nur fuer Haushalts-Reminder
  BEGIN
    INSERT INTO core.cron_labels (cron_key, package, scope, mandatory) VALUES ('zz_rb_bad', 'core', 'person', true);
    RAISE EXCEPTION 'FAIL [8e mandatory person-Reminder muss am CHECK scheitern]';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS test_fn_reminder_prefs B (Owner/Mitglied/Pflicht/route)';
END $$;

ROLLBACK;
