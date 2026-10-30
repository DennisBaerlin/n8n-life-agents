-- tests/db/core/test_fn_household_person.sql
-- WS-5d Owner-Lifecycle: Person anlegen/loeschen/ID-entknuepfen ueber die Autoring-Quelle `family`.
--   add:    Slug-Gen (sanitisiert) + Kollision (_2) + Leer-sanitisiert -> Fallback 'person'; volles
--           Skelett Pflicht (Teil-Skelett -> {ok:false}); KEIN chat_id (owner_only-Backstop umgangen)
--   unlink: telegram_user_id chirurgisch entfernt -> resolve_sender findet nichts; Re-Pair bindet wieder;
--           Owner/nicht-verknuepft -> {ok:false}
--   remove: unreferenzierte Person weg (Projektions-GC); Owner-/letzte-Person-/FK-referenziert -> {ok:false}
-- Persona = fiktiv (Mustermann), kein PII. BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

DO $$
DECLARE
  r       JSONB;
  v_uid   BIGINT;
BEGIN
  -- ===== Fixture: family (owner + partner + 2 Kinder), leeres finance_profile =====
  -- db_test: protected_contexts ist leer -> family/finance_profile frei ersetzbar.
  DELETE FROM agent.core_contexts WHERE name IN ('family','finance_profile');
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('finance_profile', 'test', 'lazy', 'prose',
          jsonb_build_object('facts', jsonb_build_object()), 'agent', 'finance');
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('family', 'test', 'static', 'prose', jsonb_build_object('facts', jsonb_build_object(
      'persons', jsonb_build_array(
        jsonb_build_object('person_id','powner','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-01-01'),
        jsonb_build_object('person_id','ppartner','first_name','Tom','last_name','Mustermann','role','partner','birth_date','1982-01-01'),
        jsonb_build_object('person_id','pchild','first_name','Lena','last_name','Mustermann','role','child','birth_date','2015-01-01'),
        jsonb_build_object('person_id','premovable','first_name','Max','last_name','Mustermann','role','child','birth_date','2017-01-01')
      ))), 'agent', 'core');

  -- ===== ADD =====
  -- (a) neue Person -> Slug 'lena2' aus dem Vornamen, projiziert
  r := agent.fn_add_household_person('{"first_name":"Lena2","last_name":"Mustermann","birth_date":"2020-05-05","role":"child"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'lena2' THEN
    RAISE EXCEPTION 'FAIL add [neue Person nicht angelegt / Slug falsch: %]', r; END IF;
  IF (SELECT role FROM agent.persons WHERE person_id = 'lena2') IS DISTINCT FROM 'child' THEN
    RAISE EXCEPTION 'FAIL add [Person nicht nach agent.persons projiziert]'; END IF;

  -- (b) Kollision: noch eine 'Lena2' -> Slug 'lena2_2'
  r := agent.fn_add_household_person('{"first_name":"Lena2","last_name":"Zweite","birth_date":"2021-06-06","role":"child"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'lena2_2' THEN
    RAISE EXCEPTION 'FAIL add [Kollisions-Suffix _2 falsch: %]', r; END IF;

  -- (c) leer-sanitisierter Vorname (nur Nicht-[a-z0-9_], steht fuer einen nicht-lateinischen Namen)
  --     -> Fallback-Slug 'person'
  r := agent.fn_add_household_person('{"first_name":"@@@","last_name":"Mustermann","birth_date":"2019-03-03","role":"child"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->>'person_id' IS DISTINCT FROM 'person' THEN
    RAISE EXCEPTION 'FAIL add [Leer-Slug-Fallback nicht "person": %]', r; END IF;

  -- (d) Teil-Skelett (kein birth_date) -> freundliches {ok:false}, kein RAISE
  r := agent.fn_add_household_person('{"first_name":"Ohne","last_name":"Datum","role":"child"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL add [Teil-Skelett ohne birth_date akzeptiert]'; END IF;

  -- (e) Umlaute/Akzente transliteriert (vorher "Ömer" -> _mer)
  r := agent.fn_add_household_person('{"first_name":"Ömer","last_name":"Mustermann","birth_date":"2016-04-04","role":"child"}'::jsonb);
  IF r->>'person_id' IS DISTINCT FROM 'oemer' THEN RAISE EXCEPTION 'FAIL add [Umlaut-Slug: %]', r; END IF;
  IF agent.fn_person_slug('Noël') IS DISTINCT FROM 'noel' OR agent.fn_person_slug('Karl-Otto') IS DISTINCT FROM 'karl_otto' THEN
    RAISE EXCEPTION 'FAIL add [Akzent/Bindestrich-Slug: % / %]', agent.fn_person_slug('Noël'), agent.fn_person_slug('Karl-Otto'); END IF;
  -- (f) Rest einer entfernten Person ('<base>__ben') -> neuer Ben erbt deren Daten nicht, bekommt ben_2
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('career_profile__ben', 'leftover', 'lazy', '', 'agent', 'career');
  IF agent.fn_person_slug('Ben') IS DISTINCT FROM 'ben_2' THEN
    RAISE EXCEPTION 'FAIL add [Rest-Zeile <base>__ben nicht beachtet: %]', agent.fn_person_slug('Ben'); END IF;
  IF agent.fn_person_slug('Ben', ARRAY['ben_2']) IS DISTINCT FROM 'ben_3' THEN
    RAISE EXCEPTION 'FAIL add [p_taken nicht beachtet]'; END IF;
  RAISE NOTICE 'PASS add [Slug-Gen, Kollision _2, Leer-Fallback "person", Teil-Skelett abgelehnt, Umlaute, Rest-Zeilen]';

  -- Sprache fester Texte (CLI-Picker): Code/freie Angabe normiert, nicht unterstuetzt -> {ok:false} ohne Write
  r := agent.fn_add_household_person('{"first_name":"Sora","last_name":"Kim","birth_date":"2018-02-02","role":"child","language":"Korean"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT pp->>'language' FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
          WHERE c.name = 'family' AND pp->>'person_id' = r->>'person_id') IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL add [language Korean -> ko: %]', r; END IF;
  r := agent.fn_add_household_person('{"first_name":"Remy","last_name":"X","birth_date":"2018-02-02","role":"child","language":"fr"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT LIKE '%language%' THEN
    RAISE EXCEPTION 'FAIL add [language fr nicht abgelehnt: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
              WHERE c.name = 'family' AND pp->>'first_name' = 'Remy') THEN
    RAISE EXCEPTION 'FAIL add [abgelehnte Person trotzdem angelegt]'; END IF;
  RAISE NOTICE 'PASS add [language normiert, nicht unterstuetzt abgelehnt]';

  -- ===== UNLINK =====
  -- ppartner eine numerische Identitaet geben, dann entknuepfen
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','ppartner','telegram_user_id',111)))));
  IF (agent.fn_resolve_sender(111)->>'person_id') IS DISTINCT FROM 'ppartner' THEN
    RAISE EXCEPTION 'FAIL unlink-setup [ppartner nicht an 111 gepairt]'; END IF;

  r := agent.fn_unlink_member_identity('{"person_id":"ppartner"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'freed_telegram_user_id')::bigint IS DISTINCT FROM 111 THEN
    RAISE EXCEPTION 'FAIL unlink [ppartner nicht entknuepft / freed uid falsch: %]', r; END IF;
  IF (agent.fn_resolve_sender(111)->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL unlink [resolve_sender findet die entknuepfte uid 111 noch]'; END IF;
  -- der Key ist WEG (nicht nur JSON-null)
  IF EXISTS (SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') pp
             WHERE c.name='family' AND pp->>'person_id'='ppartner' AND pp ? 'telegram_user_id') THEN
    RAISE EXCEPTION 'FAIL unlink [telegram_user_id-Key nicht entfernt (nur null gesetzt?)]'; END IF;

  -- Re-Pair nach Unlink: der Merge-Kern bindet eine NEUE uid wieder (kein "already paired")
  r := agent.fn_merge_member_identity('ppartner', 222, 'partner');
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL unlink [Re-Pair nach Unlink abgelehnt: %]', r; END IF;
  IF (agent.fn_resolve_sender(222)->>'person_id') IS DISTINCT FROM 'ppartner' THEN
    RAISE EXCEPTION 'FAIL unlink [Re-Pair band 222 nicht]'; END IF;

  -- unlink: OWNER ist ERLAUBT (Owner-Entscheid: Root/CLI -> nie echt aussperrbar; nur LOESCHEN bleibt blockiert)
  PERFORM agent.fn_set_context_facts(jsonb_build_object('context_name','family','facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','powner','telegram_user_id',333)))));
  r := agent.fn_unlink_member_identity('{"person_id":"powner"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'freed_telegram_user_id')::bigint IS DISTINCT FROM 333 THEN
    RAISE EXCEPTION 'FAIL unlink [Owner-Entknuepfen muss jetzt gelingen: %]', r; END IF;
  IF (agent.fn_resolve_sender(333)->>'found')::boolean THEN
    RAISE EXCEPTION 'FAIL unlink [Owner-uid 333 nach unlink noch aufloesbar]'; END IF;
  -- Re-Link-Voraussetzung (`lifeagents household pair-owner`): nach dem Owner-Unlink laesst sich ein frischer
  -- Owner-Code wieder armieren (fn_arm lehnt nur einen GEPAIRTEN Owner ab).
  r := agent.fn_arm_pairing_challenge('{"role":"owner","challenge":"REOWNER01"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL unlink [Owner-Code nach Entknuepfen nicht re-armierbar (pair-owner): %]', r; END IF;
  -- unlink: nicht verknuepfte Person -> {ok:false}
  r := agent.fn_unlink_member_identity('{"person_id":"pchild"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL unlink [nicht-verknuepfte Person akzeptiert]'; END IF;
  RAISE NOTICE 'PASS unlink [Key entfernt + freed uid + Re-Pair; Owner-Unlink erlaubt + Code re-armierbar; nicht-verknuepft abgelehnt]';

  -- ===== REMOVE =====
  -- (a) FK-referenziert: pchild besitzt ein Konto -> remove abgelehnt, Person bleibt
  INSERT INTO finance.accounts (name, account_type, owner_person_id)
  VALUES ('__test_ref_acct__', 'cash', 'pchild');
  -- Phase A: Profil-Eintraege (persons[]) von pchild/premovable/powner in einem Nicht-family-Kontext
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','pchild','steuerklasse',1),
      jsonb_build_object('person_id','premovable','steuerklasse',1),
      jsonb_build_object('person_id','powner','steuerklasse',3))))
  WHERE name = 'finance_profile';
  r := agent.fn_remove_household_person('{"person_id":"pchild"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL remove [FK-referenzierte Person geloescht: %]', r; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'pchild') THEN
    RAISE EXCEPTION 'FAIL remove [pchild nach geblocktem remove verschwunden (kein Rollback)]'; END IF;
  -- die Kaskade rollt mit zurueck: pchilds Profil-Eintrag bleibt
  IF jsonb_array_length((SELECT metadata->'facts'->'persons' FROM agent.core_contexts WHERE name='finance_profile')) <> 3 THEN
    RAISE EXCEPTION 'FAIL remove [Kaskade nicht mit zurueckgerollt]'; END IF;
  RAISE NOTICE 'PASS remove [FK-referenzierte Person nicht loeschbar, Rollback intakt]';

  -- (b) Owner -> {ok:false}
  r := agent.fn_remove_household_person('{"person_id":"powner"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL remove [Owner loeschbar]'; END IF;

  -- (c) unreferenzierte Person -> ok, verschwindet aus agent.persons
  -- P0b: + generischer Per-Person-Purge ihrer per_user-Kontexte. Setup: career_profile=per_user; je eine
  -- suffigierte PII-Zeile fuer premovable (muss weg) UND powner (muss bleiben) + eine household-Zeile (muss bleiben).
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('career_profile','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('career_profile__premovable','x','lazy','b','agent','career'),
         ('career_profile__powner','x','lazy','b','agent','career'),
         ('career_planning','x','lazy','HOUSEHOLD','agent','career')
  ON CONFLICT (name) DO NOTHING;

  -- P2b-2: person-suffigierte Advisor-Latches seeden (gefeuert): premovables muss beim Remove mit-geraeumt
  -- werden; powners + die household-Zeile 'advisor:finance' bleiben (sonst stiller Latch-Leak/Unterdrueckung).
  INSERT INTO core.notification_state (source, key, state)
  VALUES ('advisor:career:premovable','skill_gaps','fired'),
         ('advisor:career:powner','skill_gaps','fired'),
         ('advisor:finance','reserve_coverage','fired'),
         ('persona_sticker','premovable','fired'), ('persona_sticker','powner','fired')
  ON CONFLICT (source, key) DO UPDATE SET state='fired';

  r := agent.fn_remove_household_person('{"person_id":"premovable"}'::jsonb);
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL remove [unreferenzierte Person nicht geloescht: %]', r; END IF;
  IF EXISTS (SELECT 1 FROM agent.persons WHERE person_id = 'premovable') THEN
    RAISE EXCEPTION 'FAIL remove [premovable nach remove noch in agent.persons (GC?)]'; END IF;
  -- Phase A Kaskade (E9): premovables Profil-Eintrag weg, die der anderen Personen bleiben
  IF (r->>'removed_from_contexts')::int IS DISTINCT FROM 1
     OR EXISTS (SELECT 1 FROM agent.core_contexts c, jsonb_array_elements(c.metadata->'facts'->'persons') e
                WHERE c.name = 'finance_profile' AND e->>'person_id' = 'premovable')
     OR jsonb_array_length((SELECT metadata->'facts'->'persons' FROM agent.core_contexts WHERE name='finance_profile')) <> 2 THEN
    RAISE EXCEPTION 'FAIL remove [Kaskade]: Profil-Eintrag nicht/zu viel entfernt: %', r; END IF;
  -- Per-Person-Purge: nur premovables per_user-PII weg; powners bleibt; household-Kontext unberuehrt
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile__premovable') THEN
    RAISE EXCEPTION 'FAIL remove [P0b purge]: per_user-Kontext der entfernten Person nicht geloescht'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile__powner') THEN
    RAISE EXCEPTION 'FAIL remove [P0b purge]: per_user-Kontext EINER ANDEREN Person faelschlich geloescht'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_planning') THEN
    RAISE EXCEPTION 'FAIL remove [P0b purge]: household-Kontext faelschlich geloescht'; END IF;
  -- P2b-2 Latch-Purge: nur premovables Advisor-Latch weg; powners + household-Latch bleiben.
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source='advisor:career:premovable') THEN
    RAISE EXCEPTION 'FAIL remove [P2b-2 latch]: Advisor-Latch der entfernten Person nicht geraeumt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='advisor:career:powner') THEN
    RAISE EXCEPTION 'FAIL remove [P2b-2 latch]: Advisor-Latch EINER ANDEREN Person faelschlich geraeumt'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='advisor:finance') THEN
    RAISE EXCEPTION 'FAIL remove [P2b-2 latch]: household-Latch (kein pid-Segment) faelschlich geraeumt'; END IF;
  -- Sticker-Bremse: nur die der entfernten Person weg
  IF EXISTS (SELECT 1 FROM core.notification_state WHERE source='persona_sticker' AND key='premovable')
     OR NOT EXISTS (SELECT 1 FROM core.notification_state WHERE source='persona_sticker' AND key='powner') THEN
    RAISE EXCEPTION 'FAIL remove [Sticker-Bremse nicht je Person geraeumt]'; END IF;
  RAISE NOTICE 'PASS remove [Owner abgelehnt; unreferenzierte Person entfernt + Projektions-GC + per_user-Purge + Advisor-Latch-Purge]';

  -- (d) letzte verbleibende Person -> {ok:false} (Konto zuerst ent-referenzieren, dann family auf 1 Person setzen;
  --     ein DELETE des Kontos scheitert am account_balances-FK -> stattdessen owner_person_id loesen)
  UPDATE finance.accounts SET owner_person_id = NULL WHERE name = '__test_ref_acct__';
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object('persons', '[]'::jsonb))
  WHERE name = 'finance_profile';   -- sonst verwaisten die Profil-Eintraege beim family-Reset (Waisen-Pruefung)
  UPDATE agent.core_contexts SET metadata = jsonb_build_object('facts', jsonb_build_object(
      'persons', jsonb_build_array(
        jsonb_build_object('person_id','solo','first_name','Solo','last_name','Mustermann','role','child','birth_date','2016-01-01'))))
  WHERE name = 'family';
  r := agent.fn_remove_household_person('{"person_id":"solo"}'::jsonb);
  IF (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL remove [letzte verbleibende Person geloescht]'; END IF;
  RAISE NOTICE 'PASS remove [letzte verbleibende Person nicht loeschbar]';

  RAISE NOTICE 'PASS fn_add/remove/unlink_household_person [alle Invarianten]';
END $$;

ROLLBACK;
