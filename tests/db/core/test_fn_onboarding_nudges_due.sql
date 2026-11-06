-- tests/db/core/test_fn_onboarding_nudges_due.sql
-- core.fn_onboarding_nudges_due (Roter Faden): sanftes Nachfassen bei liegengebliebenem Einrichten.
--   Stufe 1 nach >= 3 Tagen ohne Fortschritt, Stufe 2 ("letzte") nach >= 10 Tagen UND >= 7 Tagen nach Stufe 1,
--   danach Ruhe — bis neue offene Abschnitte entstehen (Paket installiert: status_changed_at juenger als die letzte
--   Nachricht -> Re-Arm). Je Person hoechstens EINE Karte pro Lauf, fuer den ersten offenen Bereich in Menue-
--   Reihenfolge (p.order). Gefiltert ueber core.fn_reminder_allowed('onboarding_nudge', person) ([Nicht mehr erinnern]).
--   Mitglieder erst nach fertigem Haushalt und nur fuer persoenliche (per_user) Bereiche.
-- db_test hat KEIN seed_data -> family/registry/sections self-seeden. BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE r JSONB; n JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'nudges fixture', NULL, 'lazy', E'## fam',
          jsonb_build_object('managed_by','agent','facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','__nd_owner__','first_name','ND','last_name','Owner',
                               'role','owner','birth_date','1980-01-01','telegram_user_id',7301,'as_of','2026-10-23'),
            jsonb_build_object('person_id','__nd_partner__','first_name','ND','last_name','Partner',
                               'role','partner','birth_date','1982-01-01','telegram_user_id',7302,'as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;
  INSERT INTO core.package_registry (package, version, status) VALUES ('core','0.1.0','active'), ('finance','0.1.0','active'),
    ('estate','0.1.0','active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  UPDATE core.package_registry SET status = 'inactive' WHERE package NOT IN ('core', 'finance', 'estate');
  INSERT INTO core.cron_labels (cron_key, package, scope, default_enabled) VALUES ('onboarding_nudge', 'core', 'person', true)
    ON CONFLICT (cron_key) DO UPDATE SET scope = 'person', default_enabled = true;
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'cron_enable', 'onboarding_nudge', 'true')
    ON CONFLICT (category, key) DO UPDATE SET value = 'true';
  DELETE FROM core.notification_state WHERE source = 'onboarding_nudge';
  DELETE FROM finance.onboarding_state;
  DELETE FROM estate.onboarding_state;
  UPDATE agent.guide_onboarding_state SET status = 'completed', status_changed_at = now() - interval '20 days';
  INSERT INTO finance.onboarding_state (section_key, ord, label, status, status_changed_at) VALUES
    ('accounts', 1, 'Konten', 'completed', now() - interval '20 days'),
    ('loans', 2, 'Kredite', 'unknown', now() - interval '20 days');

  -- ---------- 1) 20 Tage still -> Stufe 1 (nie direkt Stufe 2), Bereich finance; Mitglied ohne eigene Bereiche nichts ----------
  r := core.fn_onboarding_nudges_due('{"order":["core","finance","estate"]}');
  IF jsonb_array_length(r->'nudges') <> 1 THEN RAISE EXCEPTION 'FAIL [1 genau eine Karte]: %', r; END IF;
  n := r->'nudges'->0;
  IF n->>'person_id' <> '__nd_owner__' OR (n->>'stage')::int <> 1 OR n->>'package' <> 'finance'
     OR n->>'section_key' <> 'loans' OR (n->>'chat_id')::bigint <> 7301 THEN
    RAISE EXCEPTION 'FAIL [1 Owner Stufe 1 finance/loans erwartet]: %', n; END IF;

  -- ---------- 2) gleich nochmal -> nichts (Stufe 1 gerade gesendet) ----------
  r := core.fn_onboarding_nudges_due('{"order":["core","finance","estate"]}');
  IF jsonb_array_length(r->'nudges') <> 0 THEN RAISE EXCEPTION 'FAIL [2 kein Doppel]: %', r; END IF;

  -- ---------- 3) Stufe 1 vor 8 Tagen -> Stufe 2 ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '8 days'
   WHERE source = 'onboarding_nudge' AND key = '__nd_owner__:1';
  r := core.fn_onboarding_nudges_due('{"order":["core","finance","estate"]}');
  IF jsonb_array_length(r->'nudges') <> 1 OR (r->'nudges'->0->>'stage')::int <> 2 THEN
    RAISE EXCEPTION 'FAIL [3 Stufe 2 erwartet]: %', r; END IF;

  -- ---------- 4) danach Ruhe, auch viel spaeter ----------
  UPDATE core.notification_state SET last_fired_at = now() - interval '15 days' WHERE source = 'onboarding_nudge';
  r := core.fn_onboarding_nudges_due('{"order":["core","finance","estate"]}');
  IF jsonb_array_length(r->'nudges') <> 0 THEN RAISE EXCEPTION 'FAIL [4 nach Stufe 2 Ruhe]: %', r; END IF;

  -- ---------- 5) neues Paket oeffnet Abschnitte (juenger als die letzte Karte) -> Re-Arm, Menue-Reihenfolge ----------
  INSERT INTO estate.onboarding_state (section_key, ord, label, status, status_changed_at)
    VALUES ('documents', 1, 'Dokumente', 'unknown', now() - interval '5 days');
  r := core.fn_onboarding_nudges_due('{"order":["core","estate","finance"]}');
  IF jsonb_array_length(r->'nudges') <> 1 OR (r->'nudges'->0->>'stage')::int <> 1
     OR r->'nudges'->0->>'package' <> 'estate' THEN
    RAISE EXCEPTION 'FAIL [5 Re-Arm Stufe 1 auf estate (Reihenfolge aus order)]: %', r; END IF;

  -- ---------- 6) Fortschritt vor 1 Tag -> unter 3 Tagen still ----------
  DELETE FROM core.notification_state WHERE source = 'onboarding_nudge';
  UPDATE finance.onboarding_state SET status_changed_at = now() - interval '1 day' WHERE section_key = 'accounts';
  r := core.fn_onboarding_nudges_due('{"order":["core","estate","finance"]}');
  IF jsonb_array_length(r->'nudges') <> 0 THEN RAISE EXCEPTION 'FAIL [6 Fortschritt vor 1 Tag -> nichts]: %', r; END IF;

  -- ---------- 7) [Nicht mehr erinnern] -> nichts ----------
  UPDATE finance.onboarding_state SET status_changed_at = now() - interval '20 days';
  INSERT INTO agent.reminder_prefs (person_id, cron_key, enabled) VALUES ('__nd_owner__', 'onboarding_nudge', false);
  r := core.fn_onboarding_nudges_due('{"order":["core","estate","finance"]}');
  IF jsonb_array_length(r->'nudges') <> 0 THEN RAISE EXCEPTION 'FAIL [7 abgeschaltet -> nichts]: %', r; END IF;
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source = 'onboarding_nudge') THEN
    RAISE EXCEPTION 'FAIL [7 abgeschaltet darf keine Stufe verbrauchen]'; END IF;

  -- ---------- 8) alles erledigt -> nichts ----------
  DELETE FROM agent.reminder_prefs WHERE person_id = '__nd_owner__';
  UPDATE finance.onboarding_state SET status = 'completed';
  UPDATE estate.onboarding_state SET status = 'skipped';
  r := core.fn_onboarding_nudges_due('{"order":["core","estate","finance"]}');
  IF jsonb_array_length(r->'nudges') <> 0 THEN RAISE EXCEPTION 'FAIL [8 alles erledigt -> nichts]: %', r; END IF;

  -- ---------- 9) Review-Fund: Mitglied, dessen Nachfass-Stufen verbraucht sind; ein per_user-Paket wird (neu) aktiviert,
  --            seine Abschnitte sind fuer das Mitglied noch nicht materialisiert (changed_at NULL) -> Aktivierungszeit
  --            zaehlt als Oeffnung -> Re-Arm -> Stufe 1 fuer das Mitglied ----------
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
    VALUES ('career_profile', 'per_user', 'own_user_only', 'career') ON CONFLICT (context_name) DO NOTHING;
  INSERT INTO core.package_registry (package, version, status) VALUES ('career', '0.1.0', 'active')
    ON CONFLICT (package) DO UPDATE SET status = 'active';
  UPDATE core.package_registry SET activated_at = now() - interval '5 days' WHERE package = 'career';
  DELETE FROM career.onboarding_state;
  INSERT INTO career.onboarding_state (section_key, ord, label, person_id, status, status_changed_at)
    VALUES ('profile_basics', 1, 'Profil', '__nd_owner__', 'completed', now() - interval '20 days');
  DELETE FROM core.notification_state WHERE source = 'onboarding_nudge';
  INSERT INTO core.notification_state (source, key, state, last_fired_at) VALUES
    ('onboarding_nudge', '__nd_partner__:1', 'fired', now() - interval '20 days'),
    ('onboarding_nudge', '__nd_partner__:2', 'fired', now() - interval '12 days');
  r := core.fn_onboarding_nudges_due('{"order":["core","estate","finance","career"]}');
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(r->'nudges') x
                  WHERE x->>'person_id' = '__nd_partner__' AND (x->>'stage')::int = 1 AND x->>'package' = 'career') THEN
    RAISE EXCEPTION 'FAIL [9 Mitglied: neu aktiviertes per_user-Paket re-armt -> Stufe 1 career]: %', r; END IF;

  RAISE NOTICE 'PASS test_fn_onboarding_nudges_due (Stufe 1/2, Ruhe, Re-Arm bei neuem Paket, Reihenfolge, Opt-out)';
END $$;

ROLLBACK;
