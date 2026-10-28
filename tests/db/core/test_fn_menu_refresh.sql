-- tests/db/core/test_fn_menu_refresh.sql
-- Menue-Auftrag der Mini-App (core.menu_refresh): Aenderungen, die den Knopf „Übersicht“ einer Person betreffen,
-- legen in der DB einen Auftrag an; der root-Runner (update --run-requested) bzw. jeder Menue-Lauf
-- (_set_bot_menu_buttons) uebernimmt ihn per Generation und schliesst ihn nur bei Erfolg.
--   1) family: Kopplung (telegram_user_id), Rolle, Sprache, Person neu/geloescht -> Auftrag; Name, andere Fakten, andere
--      Contexts -> keiner
--   2) core.config: nur app.enabled/app.audience mit Wertaenderung; core.app_screens: jede Aenderung
--   3) Claim/Finish: offen nur bei requested_gen > done_gen und abgelaufenem retry_after; Erfolg schliesst genau die
--      uebernommene Generation (ein Auftrag waehrend des Laufs bleibt offen); Fehlschlag -> retry_after ~10 Min
--   4) Trigger-fn ist SECURITY DEFINER (jeder Schreibweg der Fakten kann markieren); claim/finish nicht oeffentlich
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;

DELETE FROM core.menu_refresh;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family', 'menu-refresh test fixture', NULL, 'lazy', E'## fam',
        jsonb_build_object('managed_by', 'agent', 'facts', jsonb_build_object('persons', jsonb_build_array(
          jsonb_build_object('person_id', 'amr_owner', 'first_name', 'Erika', 'last_name', 'Muster', 'birth_date', '1980-01-01', 'role', 'owner',
                             'telegram_user_id', 111, 'language', 'de', 'as_of', '2026-06-11'),
          jsonb_build_object('person_id', 'amr_kid', 'first_name', 'Kim', 'last_name', 'Muster', 'birth_date', '2015-01-01', 'role', 'child', 'as_of', '2026-06-11')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata, content = excluded.content;

CREATE FUNCTION pg_temp.gen() RETURNS bigint LANGUAGE sql AS $f$
  SELECT COALESCE((SELECT requested_gen FROM core.menu_refresh), 0);
$f$;
CREATE FUNCTION pg_temp.set_person(p_pid text, p_key text, p_val jsonb) RETURNS void LANGUAGE sql AS $f$
  UPDATE agent.core_contexts c
     SET metadata = jsonb_set(c.metadata, '{facts,persons}', (
           SELECT jsonb_agg(CASE WHEN e->>'person_id' = p_pid
                                 THEN CASE WHEN p_val IS NULL THEN e - p_key ELSE jsonb_set(e, ARRAY[p_key], p_val) END
                                 ELSE e END ORDER BY o)
             FROM jsonb_array_elements(c.metadata->'facts'->'persons') WITH ORDINALITY AS x(e, o)))
   WHERE c.name = 'family';
$f$;

DO $$
DECLARE g bigint; c jsonb;
BEGIN
  -- ===== 1) family =====
  g := pg_temp.gen();
  IF g < 1 THEN RAISE EXCEPTION 'FAIL [1a] family neu angelegt -> Auftrag erwartet (gen %)', g; END IF;
  PERFORM pg_temp.set_person('amr_kid', 'first_name', '"Kimi"');
  IF pg_temp.gen() <> g THEN RAISE EXCEPTION 'FAIL [1b] Namensaenderung darf keinen Auftrag anlegen'; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,household}', '{"city":"Beispielstadt"}') WHERE name = 'family';
  IF pg_temp.gen() <> g THEN RAISE EXCEPTION 'FAIL [1c] anderer Fakt darf keinen Auftrag anlegen'; END IF;
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('amr_other', 'x', NULL, 'lazy', 'x', '{"managed_by":"agent"}');
  IF pg_temp.gen() <> g THEN RAISE EXCEPTION 'FAIL [1d] anderer Context darf keinen Auftrag anlegen'; END IF;
  PERFORM pg_temp.set_person('amr_kid', 'telegram_user_id', '333');
  IF pg_temp.gen() <> g + 1 THEN RAISE EXCEPTION 'FAIL [1e] Kopplung -> Auftrag'; END IF;
  PERFORM pg_temp.set_person('amr_kid', 'language', '"ko"');
  IF pg_temp.gen() <> g + 2 THEN RAISE EXCEPTION 'FAIL [1f] Sprachwechsel -> Auftrag'; END IF;
  PERFORM pg_temp.set_person('amr_kid', 'role', '"partner"');
  IF pg_temp.gen() <> g + 3 THEN RAISE EXCEPTION 'FAIL [1g] Rollenwechsel -> Auftrag'; END IF;
  PERFORM pg_temp.set_person('amr_kid', 'telegram_user_id', NULL);
  IF pg_temp.gen() <> g + 4 THEN RAISE EXCEPTION 'FAIL [1h] Entkoppeln -> Auftrag'; END IF;
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
           (metadata->'facts'->'persons') || '[{"person_id":"amr_new","first_name":"Neu","last_name":"Muster","birth_date":"2018-01-01","role":"child","as_of":"2026-06-11"}]'::jsonb) WHERE name = 'family';
  IF pg_temp.gen() <> g + 5 THEN RAISE EXCEPTION 'FAIL [1i] neue Person -> Auftrag'; END IF;
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons}', (SELECT jsonb_agg(e) FROM jsonb_array_elements(metadata->'facts'->'persons') e
                                                             WHERE e->>'person_id' <> 'amr_new'))
   WHERE name = 'family';
  IF pg_temp.gen() <> g + 6 THEN RAISE EXCEPTION 'FAIL [1j] Person entfernt -> Auftrag'; END IF;
  RAISE NOTICE 'PASS [1] family: Kopplung/Sprache/Rolle/Personen markieren, Name/andere Fakten/Contexts nicht';

  -- ===== 2) core.config + app_screens =====
  g := pg_temp.gen();
  INSERT INTO core.config (package, category, key, value) VALUES ('core', 'app', 'audience', 'owner')
  ON CONFLICT (category, key) DO UPDATE SET value = 'owner';
  g := pg_temp.gen();
  UPDATE core.config SET value = 'owner' WHERE category = 'app' AND key = 'audience';
  IF pg_temp.gen() <> g THEN RAISE EXCEPTION 'FAIL [2a] gleicher Wert darf keinen Auftrag anlegen'; END IF;
  UPDATE core.config SET value = 'household' WHERE category = 'app' AND key = 'audience';
  IF pg_temp.gen() <> g + 1 THEN RAISE EXCEPTION 'FAIL [2b] audience-Wechsel -> Auftrag'; END IF;
  UPDATE core.config SET value = '7200' WHERE category = 'app' AND key = 'init_data_max_age_s';
  IF pg_temp.gen() <> g + 1 THEN RAISE EXCEPTION 'FAIL [2c] anderer app-Key darf keinen Auftrag anlegen'; END IF;
  INSERT INTO core.app_screens (screen, package, handler_fn, ord, icon) VALUES ('amr_tst', 'core', 'core.fn_x', 99, '');
  IF pg_temp.gen() <> g + 2 THEN RAISE EXCEPTION 'FAIL [2d] neuer Bildschirm -> Auftrag'; END IF;
  RAISE NOTICE 'PASS [2] config nur app.enabled/audience bei Wertwechsel, app_screens immer';

  -- ===== 3) Claim / Finish =====
  g := pg_temp.gen();
  c := core.fn_menu_refresh_claim();
  IF (c->>'open')::boolean IS NOT TRUE OR (c->>'gen')::bigint <> g THEN RAISE EXCEPTION 'FAIL [3a] offen mit gen % erwartet: %', g, c; END IF;
  PERFORM pg_temp.set_person('amr_owner', 'language', '"en"');           -- Auftrag WAEHREND des Laufs
  PERFORM core.fn_menu_refresh_finish((c->>'gen')::bigint, true);
  c := core.fn_menu_refresh_claim();
  IF (c->>'open')::boolean IS NOT TRUE OR (c->>'gen')::bigint <> g + 1 THEN
    RAISE EXCEPTION 'FAIL [3b] Auftrag waehrend des Laufs muss offen bleiben: %', c; END IF;
  PERFORM core.fn_menu_refresh_finish((c->>'gen')::bigint, false);
  c := core.fn_menu_refresh_claim();
  IF (c->>'open')::boolean IS NOT FALSE OR (c->>'gen')::bigint <> g + 1 THEN
    RAISE EXCEPTION 'FAIL [3c] nach Fehlschlag Wartezeit (nicht offen, gen bleibt): %', c; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.menu_refresh WHERE retry_after BETWEEN now() + interval '9 minutes' AND now() + interval '11 minutes'
                                                       AND done_gen < requested_gen) THEN
    RAISE EXCEPTION 'FAIL [3d] retry_after ~10 Min und Auftrag offen erwartet'; END IF;
  UPDATE core.menu_refresh SET retry_after = now() - interval '1 second';
  c := core.fn_menu_refresh_claim();
  IF (c->>'open')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [3e] nach der Wartezeit wieder offen: %', c; END IF;
  PERFORM core.fn_menu_refresh_finish((c->>'gen')::bigint, true);
  PERFORM core.fn_menu_refresh_finish(1, true);                       -- alte Generation nach neuer: kein Rueckschritt
  c := core.fn_menu_refresh_claim();
  IF (c->>'open')::boolean IS NOT FALSE OR (SELECT retry_after FROM core.menu_refresh) IS NOT NULL
     OR (SELECT done_gen FROM core.menu_refresh) <> g + 1 THEN
    RAISE EXCEPTION 'FAIL [3f] Erfolg schliesst, retry_after weg, kein Rueckschritt: %', c; END IF;
  RAISE NOTICE 'PASS [3] Claim/Finish: Generationen, Auftrag im Lauf bleibt offen, Fehlschlag wartet 10 Min';

  -- [3g] dauerhaft scheiternder Chat: beim dritten Fehlschlag in Folge gibt der Auftrag auf (geschlossen + gave_up_at),
  --      ein Erfolg setzt Zaehler und Stempel zurueck
  PERFORM pg_temp.set_person('amr_owner', 'language', '"de"');
  g := pg_temp.gen();
  PERFORM core.fn_menu_refresh_finish(g, false);
  PERFORM core.fn_menu_refresh_finish(g, false);
  IF (SELECT done_gen < requested_gen AND failures = 2 AND gave_up_at IS NULL FROM core.menu_refresh) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [3g] nach 2 Fehlschlaegen offen mit Zaehler 2'; END IF;
  PERFORM core.fn_menu_refresh_finish(g, false);
  IF (SELECT done_gen = requested_gen AND failures = 0 AND retry_after IS NULL AND gave_up_at IS NOT NULL
        FROM core.menu_refresh) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [3h] dritter Fehlschlag: aufgegeben (geschlossen, gave_up_at)'; END IF;
  PERFORM pg_temp.set_person('amr_owner', 'language', '"ko"');
  PERFORM core.fn_menu_refresh_finish(pg_temp.gen(), true);
  IF (SELECT gave_up_at IS NULL AND failures = 0 AND done_gen = requested_gen FROM core.menu_refresh) IS NOT TRUE THEN
    RAISE EXCEPTION 'FAIL [3i] Erfolg setzt gave_up_at/Zaehler zurueck'; END IF;
  RAISE NOTICE 'PASS [3g-i] dritter Fehlschlag gibt auf, Erfolg setzt zurueck';

  -- ===== 4) Rechte =====
  IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'core.fn_menu_refresh_mark()'::regprocedure) THEN
    RAISE EXCEPTION 'FAIL [4a] Trigger-fn muss SECURITY DEFINER sein'; END IF;
  IF has_function_privilege('public', 'core.fn_menu_refresh_claim()', 'EXECUTE')
     OR has_function_privilege('public', 'core.fn_menu_refresh_finish(bigint, boolean)', 'EXECUTE')
     OR has_table_privilege('core_ro', 'core.menu_refresh', 'UPDATE') THEN
    RAISE EXCEPTION 'FAIL [4b] Claim/Finish duerfen nicht oeffentlich, die Tabelle fuer core_ro nicht schreibbar sein'; END IF;
  RAISE NOTICE 'PASS [4] DEFINER-Trigger, Claim/Finish nur Superuser';
END $$;
ROLLBACK;
