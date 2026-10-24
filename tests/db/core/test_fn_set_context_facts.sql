-- tests/db/core/test_fn_set_context_facts.sql
-- Testet den EINEN Fakten-Schreibweg agent.fn_set_context_facts(p jsonb) (Phase A Fakten-Konsolidierung;
-- loest fn_set_context_facts + fn_set_context_facts ab). Eigenschaften:
--   * household-Zweig (family + household-Kontexte aktiver Pakete): Zeile MUSS existieren (Installer-Skelett)
--     -> fehlt sie: {ok:false}, KEIN Insert (Sichtbarkeit agent_name bleibt paket-deklariert).
--   * per_user-Zweig: Suffix '<base>__<pid>' + INSERT-on-first-write + fail-closed (unveraendert seit P0b).
--   * Merge: reservierte Core-Form-Keys persons (Merge-Key person_id) + household; sonst Top-Level-Replace;
--     null loescht den Key; persons:null / household:null / person_id:null / _meta -> {ok:false}.
--   * Gates: family hart owner_only (ZUERST), Paket aktiv (beide Zweige), fester Binding-scope.
--   * Freundliche Pre-Validation (Core-Validator + registrierter Paket-Validator) -> {ok:false} ohne Write.
-- Self-contained (BEGIN..ROLLBACK): Stub-Validator + Test-Registry-Zeilen + family-Fixture in der Transaktion.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_row    RECORD;
  v_meta   JSONB;
BEGIN
  -- ---------- Fixtures ----------
  -- Stub-Paket-Validator (Registry-CHECK verlangt schema.fn, lowercase): akzeptiert alles ausser
  -- einem Feld 'bad' (um den freundlichen Paket-Validator-Pfad zu pruefen).
  CREATE OR REPLACE FUNCTION agent.fn_test_profile_validator(p jsonb) RETURNS text
    LANGUAGE plpgsql IMMUTABLE AS $f$
    BEGIN
      IF p ? 'bad' THEN RETURN 'field "bad" is not allowed in this profile'; END IF;
      RETURN NULL;
    END $f$;

  -- E5: das besitzende Paket muss AKTIV sein (beide Zweige).
  INSERT INTO core.package_registry (package, status) VALUES ('career', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';

  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('__test_profile__', 'agent.fn_test_profile_validator', 'career')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn, package = EXCLUDED.package;

  -- '__test_profile__' = household/owner_only; '__test_noscope__' bekommt BEWUSST KEINE Scope-Zeile (nur einen
  -- Validator) -> Test 8 prueft den defensiven missing-scope->household/owner_only-Backstop.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__test_profile__', 'household', 'owner_only', 'career')
  ON CONFLICT (context_name) DO UPDATE SET scope = EXCLUDED.scope, write_permission = EXCLUDED.write_permission, package = EXCLUDED.package;
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('__test_noscope__', 'agent.fn_test_profile_validator', 'career')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn, package = EXCLUDED.package;

  -- minimale family-Fixture: Owner erika(111) + Mitglied lena(222) -> fn_sender_is_member-Pfad
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  RAISE NOTICE 'PASS fixtures [stub validator + registry rows + active package + family]';

  -- ---------- TEST 1 (E4): household-Kontext OHNE Zeile -> {ok:false}, KEIN Insert ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__','chat_id','111',
    'facts', jsonb_build_object('current_title','Senior Developer','industry','tech')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%row missing%' THEN
    RAISE EXCEPTION 'FAIL [1] household row missing: erwartet ok=false/row missing, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__test_profile__') THEN
    RAISE EXCEPTION 'FAIL [1] household row missing: Zeile wurde trotzdem angelegt (Sichtbarkeit still global)';
  END IF;
  RAISE NOTICE 'PASS [1] household-Kontext ohne Skelett -> ok:false, kein Insert';

  -- Installer-Skelett (Muster _seed_context_skeletons): agent_name ist paket-deklariert und MUSS den Write ueberleben.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_profile__', 'skeleton', 'finance_advisor', 'lazy', '(leer)', 'agent', 'career',
          jsonb_build_object('facts', '{}'::jsonb));

  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__','chat_id','111',
    'facts', jsonb_build_object('current_title','Senior Developer','industry','tech')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'created')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [1b] household write into skeleton: erwartet ok=true/created=false, got %', v_result;
  END IF;
  SELECT agent_name, metadata INTO v_row FROM agent.core_contexts WHERE name = '__test_profile__';
  IF v_row.agent_name IS DISTINCT FROM 'finance_advisor' THEN
    RAISE EXCEPTION 'FAIL [1b] household write: agent_name (Sichtbarkeit) veraendert, got %', v_row.agent_name;
  END IF;
  IF v_row.metadata->'facts'->>'current_title' IS DISTINCT FROM 'Senior Developer'
     OR (v_row.metadata->'facts'->'_meta'->>'last_confirmed_at')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [1b] household write: facts/_meta nicht geschrieben, got %', v_row.metadata->'facts';
  END IF;
  RAISE NOTICE 'PASS [1b] Write ins Skelett [created=false, agent_name bleibt, facts + _meta]';

  -- ---------- TEST 2 (Top-Level-Merge): Folge-Write ergaenzt, ersetzt nicht ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__',
    'facts', jsonb_build_object('experience_years', 10)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [2] merge: erwartet ok=true, got %', v_result;
  END IF;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = '__test_profile__';
  IF v_meta->'facts'->>'current_title' IS DISTINCT FROM 'Senior Developer'
     OR (v_meta->'facts'->>'experience_years')::int IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'FAIL [2] merge: erwartet current_title bleibt + experience_years dazu, got %', v_meta->'facts';
  END IF;
  RAISE NOTICE 'PASS [2] Top-Level-Key-Merge [current_title bleibt + experience_years dazu]';

  -- ---------- TEST 2b (E2): Top-Level-null loescht genau diesen Key ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__',
    'facts', jsonb_build_object('industry', NULL)
  )) INTO v_result;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = '__test_profile__';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_meta->'facts' ? 'industry'
     OR v_meta->'facts'->>'current_title' IS DISTINCT FROM 'Senior Developer' THEN
    RAISE EXCEPTION 'FAIL [2b] null-delete: industry muss weg, current_title bleiben, got % / %', v_result, v_meta->'facts';
  END IF;
  RAISE NOTICE 'PASS [2b] Top-Level-null loescht nur den genannten Key';

  -- ---------- TEST 3 (Registry-Gate): unregistrierter Context -> {ok:false}, kein Write ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__not_registered__',
    'facts', jsonb_build_object('x', 1)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [3] registry-gate: erwartet ok=false fuer unregistrierten Context, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name = '__not_registered__') THEN
    RAISE EXCEPTION 'FAIL [3] registry-gate: Zeile wurde trotzdem angelegt';
  END IF;
  RAISE NOTICE 'PASS [3] Registry-Gate [unregistrierter Context -> ok:false ohne Write]';

  -- ---------- TEST 4 (owner_only-Backstop): gepairtes Mitglied (222) -> {ok:false, owner_only} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__','chat_id','222',
    'facts', jsonb_build_object('current_title','Hacked')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [4] owner_only: erwartet ok=false/owner_only, got %', v_result;
  END IF;
  IF (SELECT metadata->'facts'->>'current_title' FROM agent.core_contexts WHERE name='__test_profile__')
     IS DISTINCT FROM 'Senior Developer' THEN
    RAISE EXCEPTION 'FAIL [4] owner_only: Mitglied konnte trotzdem schreiben';
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__','chat_id','111',
    'facts', jsonb_build_object('location','Berlin')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [4b] owner allowed: erwartet ok=true, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [4] owner_only-Backstop [Mitglied 222 abgewiesen, Owner 111 schreibt]';

  -- ---------- TEST 5 (freundlicher Paket-Validator): Feld 'bad' -> {ok:false, reason} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__',
    'facts', jsonb_build_object('bad', 1)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%bad%' THEN
    RAISE EXCEPTION 'FAIL [5] package-validator: erwartet ok=false mit Validator-Grund, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='__test_profile__' AND metadata->'facts' ? 'bad') THEN
    RAISE EXCEPTION 'FAIL [5] package-validator: ungueltiges Feld wurde trotzdem geschrieben';
  END IF;
  RAISE NOTICE 'PASS [5] freundlicher Paket-Validator [Feld bad -> ok:false ohne Write]';

  -- ---------- TEST 6 (Core-Derived-Denylist, generisch): abgeleiteter Key 'age' -> {ok:false} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__',
    'facts', jsonb_build_object('age', 36)
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%derived%' THEN
    RAISE EXCEPTION 'FAIL [6] denylist: erwartet ok=false mit DERIVED-Hinweis, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [6] Core-Derived-Denylist [age -> ok:false ohne Write]';

  -- ---------- TEST 7 (Trigger-Backstop): Direkt-Write mit abgeleitetem Key -> Exception ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,start_year}', '2030')
    WHERE name = '__test_profile__';
    RAISE EXCEPTION 'FAIL [7] trigger-backstop: Direkt-UPDATE mit derived Key akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS [7] Trigger-Backstop [derived Key per Direkt-UPDATE abgewiesen: %]', SQLERRM;
  END;

  -- ---------- TEST 8 (missing-scope-Backstop): Validator ohne context_scopes-Zeile -> household/owner_only ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_noscope__', 'skeleton', NULL, 'lazy', '(leer)', 'agent', 'career', jsonb_build_object('facts', '{}'::jsonb));
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_noscope__','chat_id','222',
    'facts', jsonb_build_object('current_title','Hacked')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [8] missing-scope: erwartet ok=false/owner_only (Backstop), got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_noscope__','chat_id','111',
    'facts', jsonb_build_object('current_title','Senior Developer')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [8b] missing-scope owner: erwartet ok=true, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [8] missing-scope-Backstop [Member 222 -> owner_only; Owner 111 schreibt]';

  -- ---------- TEST 10 (E5): Paket inaktiv -> {ok:false} (household-Zweig) ----------
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'career';
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','__test_profile__','chat_id','111',
    'facts', jsonb_build_object('location','Hamburg')
  )) INTO v_result;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'career';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT metadata->'facts'->>'location' FROM agent.core_contexts WHERE name='__test_profile__') IS DISTINCT FROM 'Berlin' THEN
    RAISE EXCEPTION 'FAIL [10] package inactive (household): erwartet ok=false ohne Write, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [10] Paket inaktiv -> household-Write abgelehnt';

  -- ---------- TEST 11 (E3): reservierte Keys / _meta -> {ok:false} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', NULL))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11a] persons:null muss abgelehnt werden (Massen-Loeschung), got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('household', NULL))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11b] household:null muss abgelehnt werden, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id', NULL, 'language','de'))))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11c] person_id:null muss abgelehnt werden, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','__test_profile__',
    'facts', jsonb_build_object('_meta', jsonb_build_object('last_confirmed_at','2001-01-01')))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11d] _meta-Eingabe muss abgelehnt werden, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', 'erika'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11e] persons als String (Typ-Guard) muss abgelehnt werden, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('household', jsonb_build_array(1)))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11f] household als Array (Typ-Guard) muss abgelehnt werden, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [11g] weder facts noch content muss abgelehnt werden, got %', v_result;
  END IF;
  IF jsonb_array_length((SELECT metadata->'facts'->'persons' FROM agent.core_contexts WHERE name='family')) <> 2 THEN
    RAISE EXCEPTION 'FAIL [11] E3-Ablehnungen haben family veraendert';
  END IF;
  RAISE NOTICE 'PASS [11] E3 [persons/household/person_id null, _meta, Typ-Guards, leerer Write -> ok:false]';

  -- ---------- TEST 12 (E6): family = hart owner_only, unabhaengig von einer Registry-Zeile ----------
  -- Selbst eine (lint-verbotene) adults_only-Scope-Zeile fuer family darf den Owner-Riegel nicht lockern.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('family', 'household', 'adults_only', 'core')
  ON CONFLICT (context_name) DO UPDATE SET scope = 'household', write_permission = 'adults_only';
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family','chat_id','222',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lena','role','owner'))))) INTO v_result;
  DELETE FROM core.context_scopes WHERE context_name = 'family';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [12] family hart owner_only: erwartet ok=false/owner_only, got %', v_result;
  END IF;
  IF (SELECT metadata->'facts'->'persons'->1->>'role' FROM agent.core_contexts WHERE name='family') IS DISTINCT FROM 'partner' THEN
    RAISE EXCEPTION 'FAIL [12] family hart owner_only: Rolle wurde eskaliert';
  END IF;
  RAISE NOTICE 'PASS [12] family hart owner_only [Partner 222 kann sich nicht zum Owner machen]';

  -- ---------- TEST 13 (persons-Merge/Append/as_of/null in Person + Rueckgabe) auf family ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','lena','language','de'),
      jsonb_build_object('person_id','tom','first_name','Tom','last_name','Mustermann',
                         'role','child','birth_date','2025-03-12'))))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (v_result->>'persons_count')::int IS DISTINCT FROM 3
     OR NOT (v_result->'updated_persons' @> '["lena","tom"]'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [13] persons merge/append: erwartet ok, persons_count=3, updated_persons lena+tom, got %', v_result;
  END IF;
  -- language_missing = NUR die in diesem Write neu angehaengten Personen ohne Sprache (tom), nicht lena (Merge)
  IF v_result->'language_missing' IS DISTINCT FROM '["tom"]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [13] language_missing: erwartet ["tom"], got %', v_result->'language_missing';
  END IF;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF v_meta->'facts'->'persons'->1->>'language' IS DISTINCT FROM 'de'
     OR v_meta->'facts'->'persons'->1->>'birth_date' IS DISTINCT FROM '1985-06-21'
     OR (v_meta->'facts'->'persons'->1->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [13] persons merge: Key-Merge/as_of falsch, got %', v_meta->'facts'->'persons'->1;
  END IF;
  -- null in einer Person loescht nur diesen Key; as_of:null wird NACH der Loeschung frisch gestempelt
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','lena','language', NULL, 'as_of', NULL))))) INTO v_result;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_meta->'facts'->'persons'->1 ? 'language'
     OR (v_meta->'facts'->'persons'->1->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [13b] person null-delete: language weg + as_of frisch erwartet, got %', v_meta->'facts'->'persons'->1;
  END IF;
  -- household flach mergen + as_of; content-only-Write liefert persons_count weiter (Post-State traegt persons)
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('household', jsonb_build_object('shared_finances', true)))) INTO v_result;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF (v_meta->'facts'->'household'->>'shared_finances')::boolean IS DISTINCT FROM true
     OR (v_meta->'facts'->'household'->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [13c] household merge: got %', v_meta->'facts'->'household';
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family','content', E'## Prosa NEU')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'persons_count')::int IS DISTINCT FROM 3
     OR (SELECT content FROM agent.core_contexts WHERE name='family') IS DISTINCT FROM E'## Prosa NEU' THEN
    RAISE EXCEPTION 'FAIL [13d] content-only: erwartet ok + persons_count=3 + Prosa ersetzt, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [13] persons-Merge/Append, Person-null, household-Merge, content-only [persons_count]';

  -- ---------- TEST 13f: language wird normalisiert ('Koreanisch' -> ko); nicht unterstuetzt -> {ok:false} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','tom','language','Koreanisch'))))) INTO v_result;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT pp->>'language' FROM jsonb_array_elements(v_meta->'facts'->'persons') pp
          WHERE pp->>'person_id' = 'tom') IS DISTINCT FROM 'ko'
     OR v_result->'language_missing' IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [13f] language normalisieren: erwartet ko + language_missing [], got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','tom','language','Klingonisch'))))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT LIKE '%language%' THEN
    RAISE EXCEPTION 'FAIL [13f] nicht unterstuetzte Sprache: erwartet ok=false mit language-Grund, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [13f] language normalisiert + Wertevorrat, language_missing nur fuer Neue';

  -- ---------- TEST 13e: Prosa-Replace erhaelt den system-verwalteten "## Gelernt"-Block ----------
  UPDATE agent.core_contexts
  SET content = E'## Prosa NEU\n\n## Gelernt\n\n- mag Klartext (gelernt am 2026-10-01 aus Chat)'
  WHERE name = 'family';
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family',
    'content', E'## Prosa V2\n\n## Gelernt\n- erfundene Notiz')) INTO v_result;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT content FROM agent.core_contexts WHERE name='family') NOT LIKE '## Prosa V2%'
     OR (SELECT content FROM agent.core_contexts WHERE name='family') NOT LIKE '%mag Klartext%'
     OR (SELECT content FROM agent.core_contexts WHERE name='family') LIKE '%erfundene Notiz%' THEN
    RAISE EXCEPTION 'FAIL [13e] Gelernt-Block: erwartet neuer Text + bestaetigte Notiz, ohne Fremd-Block, got %',
      (SELECT content FROM agent.core_contexts WHERE name='family');
  END IF;
  RAISE NOTICE 'PASS [13e] Prosa-Replace erhaelt den Gelernt-Block, verwirft einen mitgeschickten';

  -- ---------- TEST 14 (E7): fester Binding-scope ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object('context_name','family','scope','per_user',
    'facts', jsonb_build_object('household', jsonb_build_object('care_flag', false)))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [14] scope-mismatch (per_user-Bindung auf family): erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [14] fester Binding-scope [Mismatch -> ok:false]';
END $$;

-- ---------- TEST 9 (P0b PER-USER): own_user_only Suffix-Speicher + fail-closed + neue Gates ----------
DO $$
DECLARE
  v_result JSONB;
BEGIN
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('test_peruser_ctx', 'agent.fn_test_profile_validator', 'career')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('test_peruser_ctx', 'per_user', 'own_user_only', 'career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';

  -- Owner(111) schreibt -> suffigierte Zeile 'test_peruser_ctx__erika' (INSERT-on-first-write), KEINE Basis-Zeile
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','111','scope','per_user',
    'facts', jsonb_build_object('current_title','Erika Dev'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'created')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [9] per_user owner write: erwartet ok=true/created=true, got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_peruser_ctx__erika'
                 AND metadata->'facts'->>'current_title'='Erika Dev'
                 AND managed_by='agent' AND load_strategy='lazy' AND package='career') THEN
    RAISE EXCEPTION 'FAIL [9] per_user owner write: suffigierte Zeile __erika fehlt/typisierte Spalten falsch';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_peruser_ctx') THEN
    RAISE EXCEPTION 'FAIL [9] per_user owner write: Basis-Zeile (ohne Suffix) wurde faelschlich angelegt';
  END IF;
  RAISE NOTICE 'PASS [9] per_user own_user_only [Owner schreibt -> __erika, KEINE Basis-Zeile]';

  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','222',
    'facts', jsonb_build_object('current_title','Lena PM'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_peruser_ctx__lena')
     OR (SELECT metadata->'facts'->>'current_title' FROM agent.core_contexts WHERE name='test_peruser_ctx__erika')
        IS DISTINCT FROM 'Erika Dev' THEN
    RAISE EXCEPTION 'FAIL [9b] per_user member own write / cross-write isolation, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [9b] per_user own_user_only [Member 222 -> __lena; __erika unberuehrt]';

  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','999',
    'facts', jsonb_build_object('current_title','Ghost'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR v_result->>'reason' NOT ILIKE '%cannot resolve person%'
     OR EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_peruser_ctx') THEN
    RAISE EXCEPTION 'FAIL [9c] per_user fail-closed: erwartet ok=false/cannot resolve person, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [9c] per_user fail-closed [numerisch-nicht-in-family -> ok:false, KEINE Basis-Zeile]';

  -- E8: per_user-Kontexte tragen KEIN persons (Haushalts-Form)
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','111',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika'))))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [9d] per_user + persons: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [9d] per_user-Kontext lehnt persons ab';

  -- E7: household-Bindung (Guide) darf keinen per_user-Kontext schreiben
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','111','scope','household',
    'facts', jsonb_build_object('current_title','Via Guide'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT metadata->'facts'->>'current_title' FROM agent.core_contexts WHERE name='test_peruser_ctx__erika')
        IS DISTINCT FROM 'Erika Dev' THEN
    RAISE EXCEPTION 'FAIL [9e] scope-mismatch (household-Bindung auf per_user): erwartet ok=false ohne Write, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [9e] household-Bindung kann keinen per_user-Kontext schreiben';

  -- E5: Paket inaktiv -> auch per_user abgelehnt
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'career';
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx','chat_id','111',
    'facts', jsonb_build_object('current_title','Inactive'))) INTO v_result;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'career';
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [9f] per_user package inactive: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [9f] Paket inaktiv -> per_user-Write abgelehnt';
END $$;

-- ---------- TEST 16 (Mitglieder-Selbstpflege): Suffix-Trick + Plan-Kontexte gesperrt ----------
-- Vorbedingung fuer die Stufe self (agent.tool_set_own_context_facts): ein Mitglied darf ueber den per_user-Weg
-- (a) keinen fremden Personen-Kontext per Suffix-Namen adressieren und (b) kein Plan-Dokument (core.advisors.
-- plan_context) direkt schreiben — Plaene laufen nur ueber fn_advisor_publish_plan (owner_only). Gilt fuer ALLE.
DO $$
DECLARE
  v_result JSONB;
BEGIN
  -- (a) Lena (222) adressiert Erikas Zeile direkt ueber den Suffix-Namen -> abgelehnt, Erika unberuehrt
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_peruser_ctx__erika','chat_id','222','scope','per_user',
    'facts', jsonb_build_object('current_title','Hijack'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR (SELECT metadata->'facts'->>'current_title' FROM agent.core_contexts WHERE name='test_peruser_ctx__erika')
        IS DISTINCT FROM 'Erika Dev' THEN
    RAISE EXCEPTION 'FAIL [16a] Suffix-Trick: erwartet ok=false ohne Write, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [16a] Suffix-Name eines fremden Kontexts -> abgelehnt';

  -- (b) Plan-Kontext (per_user, own_user_only, als plan_context registriert) -> fuer Mitglied UND Owner abgelehnt
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('test_plan_ctx', 'agent.fn_test_profile_validator', 'career')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('test_plan_ctx', 'per_user', 'own_user_only', 'career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user', write_permission='own_user_only';
  INSERT INTO core.advisors (domain, plan_context, review_fn, package)
  VALUES ('__t_plan_dom__', 'test_plan_ctx', 'agent.fn_test_review', 'career')
  ON CONFLICT (domain) DO UPDATE SET plan_context = EXCLUDED.plan_context;

  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_plan_ctx','chat_id','222','scope','per_user',
    'content', E'# Mein Plan (ueberschrieben)')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%plan%'
     OR EXISTS (SELECT 1 FROM agent.core_contexts WHERE name LIKE 'test_plan_ctx%') THEN
    RAISE EXCEPTION 'FAIL [16b] Plan-Kontext durch Mitglied: erwartet ok=false (plan) ohne Write, got %', v_result;
  END IF;
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','test_plan_ctx','chat_id','111','scope','per_user',
    'facts', jsonb_build_object('current_title','x'))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT ILIKE '%plan%' THEN
    RAISE EXCEPTION 'FAIL [16b] Plan-Kontext durch Owner: erwartet ok=false (plan), got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [16b] Plan-Kontext (core.advisors.plan_context) -> fuer alle abgelehnt (nur publish_plan)';

  -- (c) family ueber den per_user-Weg durch ein Mitglied -> owner_only (family-Gate greift zuerst)
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family','chat_id','222','scope','per_user',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lena','role','owner'))))) INTO v_result;
  IF v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL [16c] family per_user durch Mitglied: erwartet owner_only, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [16c] family ueber per_user-Weg durch Mitglied -> owner_only';
END $$;

-- ---------- TEST 15 (E1): die abgeloesten fns existieren nicht mehr ----------
DO $$
BEGIN
  IF to_regprocedure('agent.fn_set_household_facts(jsonb)') IS NOT NULL
     OR to_regprocedure('agent.fn_set_profile_facts(jsonb)') IS NOT NULL
     OR to_regprocedure('agent.fn_finance_profile_context(text)') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [15] alte fns noch vorhanden (core:V019 nicht angewandt?)';
  END IF;
  RAISE NOTICE 'PASS [15] fn_set_household_facts / fn_set_profile_facts / fn_finance_profile_context entfernt';
END $$;

ROLLBACK;
