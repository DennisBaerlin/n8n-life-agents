-- tests/db/core/test_fn_reminders_overview.sql
-- core.fn_reminders_overview(chat_id) — Datenmodell des /reminders-Menues (Roter Faden, Paket B):
--   je Registry-Reminder {key, package, scope, mandatory, active, enabled, schedule} aus Sicht des Betrachters:
--   Owner sieht Haushalts- + Person-Reminder (enabled = Notschalter bzw. seine eigene Einstellung), ein Mitglied
--   nur die Person-Reminder (Haushalt schaltet der Owner). active = Paket aktiv. schedule = core.config schedule.<key>.
--   Unaufgeloester Betrachter -> leere Liste. Lesbar unter core_ro (der Menue-Sub liest unter core_ro).
BEGIN;

DO $$
DECLARE r JSONB; e JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'reminders_overview fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__ro_owner__','first_name','RO','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7501,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__ro_partner__','first_name','RO','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7502,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO core.package_registry (package, version, status) VALUES ('core', '0.1.0', 'active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  DELETE FROM core.cron_labels WHERE cron_key LIKE 'zz_ro_%';
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled, mandatory) VALUES
    ('zz_ro_house', 'core', 'household', true, false),
    ('zz_ro_person', 'core', 'person', false, false),
    ('zz_ro_must', 'core', 'household', true, true),
    ('zz_ro_gone', 'zz_nopkg', 'household', true, false);
  INSERT INTO core.config (package, category, key, value) VALUES
    ('core', 'cron_enable', 'zz_ro_house', 'false'), ('core', 'cron_enable', 'zz_ro_person', 'true'),
    ('core', 'cron_enable', 'zz_ro_must', 'true'),
    ('core', 'schedule', 'zz_ro_house', '5 10 3,17 * *')
  ON CONFLICT (category, key) DO UPDATE SET value = EXCLUDED.value;
  INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled) VALUES ('__ro_owner__', 'zz_ro_person', true);

  SET LOCAL ROLE core_ro;
  -- Owner: alle vier, enabled je Ebene
  r := core.fn_reminders_overview('7501');
  IF r->>'viewer_role' <> 'owner' THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Owner-Rolle]: %', r; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'reminders') x WHERE x->>'key' = 'zz_ro_house';
  IF (e->>'enabled')::boolean IS NOT FALSE OR e->>'schedule' <> '5 10 3,17 * *' OR (e->>'active')::boolean IS NOT TRUE THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [Owner Haushalt aus + Zeitplan]: %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'reminders') x WHERE x->>'key' = 'zz_ro_person';
  IF (e->>'enabled')::boolean IS NOT TRUE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Owner Person-Reminder eigene Einstellung an]: %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'reminders') x WHERE x->>'key' = 'zz_ro_must';
  IF (e->>'mandatory')::boolean IS NOT TRUE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Pflicht-Flag]: %', e; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'reminders') x WHERE x->>'key' = 'zz_ro_gone';
  IF (e->>'active')::boolean IS NOT FALSE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Paket nicht aktiv -> active false]: %', e; END IF;

  -- Mitglied: nur Person-Reminder, Default aus
  r := core.fn_reminders_overview('7502');
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(r->'reminders') x WHERE x->>'scope' <> 'person' AND x->>'key' LIKE 'zz_ro_%') THEN
    RESET ROLE; RAISE EXCEPTION 'FAIL [Mitglied sieht nur Person-Reminder]: %', r; END IF;
  SELECT x INTO e FROM jsonb_array_elements(r->'reminders') x WHERE x->>'key' = 'zz_ro_person';
  IF (e->>'enabled')::boolean IS NOT FALSE THEN RESET ROLE; RAISE EXCEPTION 'FAIL [Mitglied Default aus]: %', e; END IF;

  -- Unbekannt: leer
  r := core.fn_reminders_overview('999999');
  IF jsonb_array_length(r->'reminders') <> 0 THEN RESET ROLE; RAISE EXCEPTION 'FAIL [unbekannt -> leer]: %', r; END IF;
  RESET ROLE;
  RAISE NOTICE 'PASS test_fn_reminders_overview (Owner/Mitglied/Pflicht/inaktiv, unter core_ro)';
END $$;

ROLLBACK;
