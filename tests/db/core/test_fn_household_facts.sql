-- tests/db/core/test_fn_household_facts.sql
-- Testet die Haushalts-Fakten-Schicht auf agent.core_contexts (md-first + metadata.facts-Sidecar):
--   * trg_validate_household_facts (DB-Gesetz: Skelett-Felder, Datums-Casts, Eindeutigkeit)
--   * trg_core_contexts_protect    (registriert in core.protected_contexts -> DELETE unmoeglich, WS-B2b)
--   * fn_set_context_facts       (HITL-Write: atomarer Key-Merge, {ok:false} fuer Korrigierbares)
--   * fn_resolve_person            (Resolver-Muster: name/alias -> person_id, hit_count, candidates)
--   * fn_resolve_sender            (telegram_user_id -> Person; Identity-Link)
-- Fixture: die ECHTEN Zeilen 'family'/'finance_profile' werden in der Transaktion ge-upsertet
-- (BEGIN...ROLLBACK -> kein Residual-State).
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_meta   JSONB;
  v_id     TEXT;
  v_cnt    INT;
BEGIN

  -- ---------- Fixture: family-Zeile mit gueltigem Facts-Sidecar ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa\nErika mag Klartext.',
          jsonb_build_object(
            'managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                   'aliases', jsonb_build_array('Erika'), 'role','owner',
                                   'birth_date','1980-05-20','telegram_user_id',111,
                                   'language','de','as_of','2026-06-11'),
                jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                   'aliases', jsonb_build_array('Lena','meine Frau'), 'role','partner',
                                   'birth_date','1985-06-21','telegram_user_id',222,
                                   'language','ko','as_of','2026-06-11'),
                jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','Mustermann',
                                   'role','child','birth_date','2023-02-17','as_of','2026-06-11')
              ),
              'household', jsonb_build_object('shared_finances', true, 'as_of','2026-06-11')
            )))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('finance_profile', 'test fixture', 'finance_advisor', 'lazy', E'## Finanz-Profil Prosa',
          jsonb_build_object(
            'managed_by','agent','protected', true,             'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','erika','planned_retirement_age',63,
                                   'steuerklasse',3,'vorsorgesystem','grv','as_of','2026-06-11'),
                jsonb_build_object('person_id','lena','as_of','2026-06-11')
              ))))
  ON CONFLICT (name) DO UPDATE
    SET description = EXCLUDED.description, content = EXCLUDED.content, metadata = EXCLUDED.metadata;

  -- Registry-Zeile (Host-Seed-Aequivalent aus packages/finance/manifest.json): der Core-Trigger
  -- dispatcht finance_profile-Strukturregeln GENERISCH ueber core.context_validators (WS-B1/D12).
  -- db_test seedet die Registry nicht (kein seed_data im Container) -> der Test seedet sie selbst,
  -- damit die finance_profile-Dispatch-Tests (TEST 4/5/...) greifen.
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET validate_fn = EXCLUDED.validate_fn, package = EXCLUDED.package;
  -- Install-UX-Phase 6: finance_profile ist nur beschreibbar, solange finance AKTIV installiert ist
  -- (core.fn_facts_context_allowed) -> die Registry-Zeile gehoert zur Fixture.
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';

  RAISE NOTICE 'PASS household fixture [family + finance_profile upserted, Trigger akzeptiert gueltiges Skelett]';

  -- ---------- TEST 1 (Trigger-Backstop): kaputtes birth_date per Direkt-UPDATE -> Exception ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,0,birth_date}', '"33.13.1990"')
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [bad birth_date]: UPDATE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_validate_household_facts [invalides birth_date abgewiesen: %]', SQLERRM;
  END;

  -- ---------- TEST 2 (Trigger): doppelte telegram_user_id ueber Personen -> Exception ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,1,telegram_user_id}', '111')
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [dup telegram_user_id]: UPDATE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_validate_household_facts [doppelte telegram_user_id abgewiesen]';
  END;

  -- ---------- TEST 3 (Trigger): person ohne last_name -> Exception (Owner-Vorgabe Vor+Nachname) ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,0,last_name}', '" "')
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [empty last_name]: UPDATE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_validate_household_facts [leerer last_name abgewiesen]';
  END;

  -- ---------- TEST 4 (Trigger): finance_profile mit unbekannter person_id -> Exception (Single-Writer-Referenz) ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,0,person_id}', '"ghost"')
    WHERE name = 'finance_profile';
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [unknown person_id]: UPDATE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_validate_household_facts [finance_profile referenziert nur family-Personen]';
  END;

  -- ---------- TEST 5 (Trigger): Steuerklasse 9 -> Exception ----------
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,0,steuerklasse}', '9')
    WHERE name = 'finance_profile';
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [steuerklasse 9]: UPDATE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_validate_household_facts [Steuerklasse ausserhalb 1..6 abgewiesen]';
  END;

  -- ---------- TEST 6 (Protect): DELETE auf geschuetzte Zeile -> Exception, selbst via SQL ----------
  -- WS-B2b: Schutz via core.protected_contexts (db_test hat kein seed_data -> Registry-Zeile self-seeden).
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('family', 'core') ON CONFLICT DO NOTHING;
  BEGIN
    DELETE FROM agent.core_contexts WHERE name = 'family';
    RAISE EXCEPTION 'FAIL trg_core_contexts_protect: DELETE wurde akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS trg_core_contexts_protect [protected family nicht loeschbar]';
  END;

  -- Nicht-protected Zeile bleibt loeschbar (Kontrolle, kein Overblocking)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__test_unprotected__', 'x', 'lazy', 'x')
  ON CONFLICT (name) DO NOTHING;
  DELETE FROM agent.core_contexts WHERE name = '__test_unprotected__';
  RAISE NOTICE 'PASS trg_core_contexts_protect [nicht-protected weiterhin loeschbar]';

  -- ---------- TEST 6b (Trigger-Backstop): language nur aus core.ui_languages ----------
  v_id := NULL;
  BEGIN
    UPDATE agent.core_contexts
       SET metadata = jsonb_set(metadata, '{facts,persons,0,language}', '"Deutsch"')
     WHERE name = 'family';
  EXCEPTION WHEN raise_exception THEN
    v_id := SQLERRM;
  END;
  IF v_id IS NULL OR v_id NOT LIKE '%language%' THEN
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [language "Deutsch" akzeptiert: %]', v_id;
  END IF;
  RAISE NOTICE 'PASS trg_validate_household_facts [language nur Codes aus core.ui_languages]';

  -- ---------- TEST 6c (Trigger-Backstop): persona nur aus core.ui_personas, 'neutral' nie gespeichert ----------
  v_id := NULL;
  BEGIN
    UPDATE agent.core_contexts
       SET metadata = jsonb_set(metadata, '{facts,persons,0,persona}', '"pirate"')
     WHERE name = 'family';
  EXCEPTION WHEN raise_exception THEN
    v_id := SQLERRM;
  END;
  IF v_id IS NULL OR v_id NOT LIKE '%persona%' THEN
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [persona "pirate" akzeptiert: %]', v_id;
  END IF;
  v_id := NULL;
  BEGIN
    UPDATE agent.core_contexts
       SET metadata = jsonb_set(metadata, '{facts,persons,0,persona}', '"neutral"')
     WHERE name = 'family';
  EXCEPTION WHEN raise_exception THEN
    v_id := SQLERRM;
  END;
  IF v_id IS NULL OR v_id NOT LIKE '%persona%' THEN
    RAISE EXCEPTION 'FAIL trg_validate_household_facts [persona "neutral" gespeichert: %]', v_id;
  END IF;
  UPDATE agent.core_contexts
     SET metadata = jsonb_set(metadata, '{facts,persons,0,persona}', '"butler"')
   WHERE name = 'family';
  UPDATE agent.core_contexts
     SET metadata = metadata #- '{facts,persons,0,persona}'
   WHERE name = 'family';
  RAISE NOTICE 'PASS trg_validate_household_facts [persona nur Codes aus core.ui_personas, neutral = kein Key]';

  -- ---------- TEST 7 (fn_set_context_facts): Merge bestehende Person + as_of-Stempel ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lena','language','de')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [merge]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT metadata INTO v_meta FROM agent.core_contexts WHERE name = 'family';
  IF v_meta->'facts'->'persons'->1->>'language' IS DISTINCT FROM 'de' THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [merge]: language nicht gemerged, got %', v_meta->'facts'->'persons'->1;
  END IF;
  IF v_meta->'facts'->'persons'->1->>'birth_date' IS DISTINCT FROM '1985-06-21' THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [merge]: bestehende Keys verloren';
  END IF;
  IF (v_meta->'facts'->'persons'->1->>'as_of')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [merge]: as_of nicht auf heute gestempelt';
  END IF;
  IF (v_meta->'facts'->'_meta'->>'last_confirmed_at')::date IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [merge]: _meta.last_confirmed_at fehlt';
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [Key-Merge + as_of/last_confirmed_at]';

  -- ---------- TEST 8 (fn): neue Person anhaengen ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object(
      'person_id','tom','first_name','Tom','last_name','Mustermann',
      'role','child','birth_date','2025-03-12')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (v_result->>'persons_count')::int IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [append]: erwartet ok+persons_count=4, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [neue Person angehaengt, persons_count=4]';

  -- ---------- TEST 9 (fn, korrigierbar): unvollstaendige NEUE Person -> {ok:false}, kein Write ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','neu','first_name','Nur Vorname')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [invalid new person]: erwartet ok=false, got %', v_result;
  END IF;
  SELECT jsonb_array_length(metadata->'facts'->'persons') INTO v_cnt
  FROM agent.core_contexts WHERE name = 'family';
  IF v_cnt IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [invalid new person]: Write passierte trotzdem (%)', v_cnt;
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [invalide Person -> ok:false ohne Write]';

  -- ---------- TEST 10 (fn, korrigierbar): unbekannter context_name -> {ok:false} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','global_instructions',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','language','en')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [context allowlist]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [Context-Allowlist family/finance_profile]';

  -- ---------- TEST 10b (Install-UX-Phase 6): finance_profile nur bei AKTIVEM finance ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','finance_profile',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','steuerklasse',4)))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [finance aktiv]: erwartet ok=true, got %', v_result;
  END IF;
  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','finance_profile',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','steuerklasse',3)))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [finance inaktiv]: erwartet ok=false, got %', v_result;
  END IF;
  IF (SELECT (metadata->'facts'->'persons'->0->>'steuerklasse')::int FROM agent.core_contexts WHERE name = 'finance_profile') <> 4 THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [finance inaktiv]: Write passierte trotzdem';
  END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'finance';
  RAISE NOTICE 'PASS fn_set_context_facts [finance_profile nur bei aktivem finance-Paket]';

  -- ---------- TEST 11 (fn): optionaler Prosa-Replace (Interim-Pfad p_content) ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'content', E'## Prosa NEU\nAktualisiert.'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [content]: erwartet ok=true, got %', v_result;
  END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name='family') NOT LIKE '%Prosa NEU%' THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [content]: Prosa nicht ersetzt';
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [Prosa-Replace im selben Gate]';

  -- ---------- TEST 11b (WS-5b owner_only-Backstop): gepairter Nicht-Owner darf Haushalts-Fakten NICHT aendern ----------
  -- set_household_facts mergt role/telegram_user_id = die Identitaets-Quelle selbst -> ein Mitglied
  -- koennte sich sonst zum Owner eskalieren. chat_id=222 (lena, partner) -> {ok:false, owner_only}, KEIN Write.
  SELECT jsonb_array_length(metadata->'facts'->'persons') INTO v_cnt FROM agent.core_contexts WHERE name = 'family';
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family', 'chat_id','222',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lena','role','owner')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [member self-escalation]: erwartet ok=false/owner_only, got %', v_result;
  END IF;
  IF (SELECT metadata->'facts'->'persons'->1->>'role' FROM agent.core_contexts WHERE name='family') IS DISTINCT FROM 'partner' THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [member self-escalation]: Rolle wurde trotzdem geaendert';
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [gepairter Nicht-Owner -> owner_only, keine Rollen-Eskalation]';

  -- Owner (erika@111) darf -> ok (Kontrolle, kein Overblocking). Zustands-neutral: lena.language bleibt 'de'
  -- (aus TEST 7) -> keine Kollision mit der spaeteren fn_resolve_sender-Assertion.
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family', 'chat_id','111',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lena','language','de')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_set_context_facts [owner allowed]: erwartet ok=true, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_set_context_facts [Owner-chat_id weiterhin erlaubt]';

  -- ---------- TEST 12 (fn_resolve_person): eindeutig per Vorname ----------
  SELECT person_id INTO v_id FROM core.fn_resolve_person('erika');
  IF v_id IS DISTINCT FROM 'erika' THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [vorname]: erwartet erika, got %', v_id;
  END IF;

  -- eindeutig per Alias (case-insensitiv)
  SELECT person_id INTO v_id FROM core.fn_resolve_person('MEINE FRAU');
  IF v_id IS DISTINCT FROM 'lena' THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [alias]: erwartet lena, got %', v_id;
  END IF;

  -- eindeutig per vollem Namen
  SELECT person_id INTO v_id FROM core.fn_resolve_person('Lena Beispiel');
  IF v_id IS DISTINCT FROM 'lena' THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [full name]: erwartet lena, got %', v_id;
  END IF;

  -- mehrdeutig: Nachname Mustermann matcht 3 Personen -> id NULL, hit_count=3
  SELECT hit_count INTO v_cnt FROM core.fn_resolve_person('Mustermann');
  IF v_cnt < 2 THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [ambiguous]: erwartet hit_count>=2, got %', v_cnt;
  END IF;
  SELECT person_id INTO v_id FROM core.fn_resolve_person('Mustermann');
  IF v_id IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [ambiguous]: person_id muss NULL sein, got %', v_id;
  END IF;

  -- 0 Treffer
  SELECT hit_count INTO v_cnt FROM core.fn_resolve_person('Unbekannt');
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [no hit]: erwartet 0, got %', v_cnt;
  END IF;
  -- 0 Treffer -> ALLE Haushaltsmitglieder als candidates (Auswahl statt Nachname-Rueckfrage, Owner-Befund 2026-10-23)
  SELECT jsonb_array_length(candidates) INTO v_cnt FROM core.fn_resolve_person('Unbekannt');
  IF v_cnt < 3 OR NOT EXISTS (SELECT 1 FROM core.fn_resolve_person('Unbekannt') r, jsonb_array_elements(r.candidates) c
                              WHERE c->>'person_id' = 'lena' AND c->>'full_name' = 'Lena Beispiel' AND c ? 'role') THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [no hit -> Haushalt als Kandidaten]: % Kandidat(en)', v_cnt;
  END IF;
  SELECT jsonb_array_length(candidates) INTO v_cnt FROM core.fn_resolve_person(NULL);
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_resolve_person [leer -> keine Kandidaten]: %', v_cnt;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_person [vorname/alias/fullname/ambig/none + Haushalt-Kandidaten]';

  -- ---------- TEST 12b (Renteninformation-Plan 2026-10-26): Selbstbezug = wer gerade chattet ----------
  SELECT person_id INTO v_id FROM core.fn_resolve_person('ich', '111');          -- Owner erika chattet
  IF v_id IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [ich @111]: got %', v_id; END IF;
  SELECT person_id INTO v_id FROM core.fn_resolve_person(' Mein ', '222');       -- lena chattet
  IF v_id IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [mein @222]: got %', v_id; END IF;
  SELECT person_id INTO v_id FROM core.fn_resolve_person('myself', '222');
  IF v_id IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [myself @222]: got %', v_id; END IF;
  SELECT person_id INTO v_id FROM core.fn_resolve_person('나', '111');
  IF v_id IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [나 @111]: got %', v_id; END IF;
  -- nur der GANZE Wert: "meine Frau" bleibt der Alias von lena, auch wenn erika chattet
  SELECT person_id INTO v_id FROM core.fn_resolve_person('meine Frau', '111');
  IF v_id IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [meine Frau @111]: got %', v_id; END IF;
  -- ohne/kaputte/unbekannte chat_id: Selbstbezug bleibt unaufgeloest (0 Treffer, kein Fehler)
  SELECT hit_count INTO v_cnt FROM core.fn_resolve_person('ich', 'test_9999');
  IF v_cnt IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL fn_resolve_person [ich @test_9999]: %', v_cnt; END IF;
  SELECT hit_count INTO v_cnt FROM core.fn_resolve_person('ich', '999');
  IF v_cnt IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL fn_resolve_person [ich @999 unbekannt]: %', v_cnt; END IF;
  SELECT hit_count INTO v_cnt FROM core.fn_resolve_person('ich');
  IF v_cnt IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL fn_resolve_person [ich ohne chat_id]: %', v_cnt; END IF;
  -- normale Namen unveraendert, auch mit chat_id
  SELECT person_id INTO v_id FROM core.fn_resolve_person('Lena Beispiel', '111');
  IF v_id IS DISTINCT FROM 'lena' THEN RAISE EXCEPTION 'FAIL fn_resolve_person [Name @111]: got %', v_id; END IF;
  RAISE NOTICE 'PASS fn_resolve_person [Selbstbezug = Absender, nur ganzer Wert, kaputte chat_id -> 0 Treffer]';

  -- ---------- TEST 13 (fn_resolve_sender): telegram_user_id -> Person ----------
  SELECT agent.fn_resolve_sender(222) INTO v_result;
  IF (v_result->>'found')::boolean IS DISTINCT FROM true
     OR v_result->>'person_id' IS DISTINCT FROM 'lena'
     OR v_result->>'full_name' IS DISTINCT FROM 'Lena Beispiel'
     OR v_result->>'language'  IS DISTINCT FROM 'de' THEN  -- nach TEST 7 auf de gemerged
    RAISE EXCEPTION 'FAIL fn_resolve_sender [known]: got %', v_result;
  END IF;
  SELECT agent.fn_resolve_sender(999) INTO v_result;
  IF (v_result->>'found')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_resolve_sender [unknown]: erwartet found=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_sender [Identity-Link known/unknown]';

  -- ---------- TEST 14 (Review: Derived-Key-Denylist): age statt birth_date -> {ok:false}, kein Write ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','age',36)))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR v_result->>'reason' NOT ILIKE '%derived%' THEN
    RAISE EXCEPTION 'FAIL denylist [age]: erwartet ok=false mit DERIVED-Hinweis, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts
             WHERE name='family' AND metadata->'facts'->'persons'->0 ? 'age') THEN
    RAISE EXCEPTION 'FAIL denylist [age]: Key wurde trotzdem geschrieben';
  END IF;
  RAISE NOTICE 'PASS denylist [abgeleiteter Key age -> ok:false ohne Write; open-world fuer echte Fakten bleibt]';

  -- Gegenprobe open-world (Owner-R5): ein NEUER echter Fakten-Key (pflegegrad) geht durch
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','pflegegrad','keiner')))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL denylist [open-world]: echter neuer Key abgelehnt, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS denylist [open-world: neuer Rohfakt-Key pflegegrad erlaubt]';

  -- ---------- TEST 15 (Review: as_of-Clamp): Zukunfts-Datum -> {ok:false} ----------
  SELECT agent.fn_set_context_facts(jsonb_build_object(
    'context_name','family',
    'facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object(
      'person_id','erika','as_of', to_char(CURRENT_DATE + 1, 'YYYY-MM-DD'))))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL as_of-Clamp: Zukunfts-as_of akzeptiert, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS as_of-Clamp [Zukunfts-Datum -> ok:false]';

  -- ---------- TEST 16 (Review: bidirektionaler Single-Writer): family-Write darf fp-Refs nicht verwaisen ----------
  -- fp-Fixture referenziert erika+lena; family auf nur erika+lisa+tom reduzieren -> lena verwaist -> Exception
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons}',
        (SELECT jsonb_agg(p) FROM jsonb_array_elements(metadata->'facts'->'persons') p
         WHERE p->>'person_id' <> 'lena'))
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL bidirektional: family-Update mit verwaister fp-Referenz akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS bidirektional [family-Write blockt verwaiste finance_profile-Referenz: %]', SQLERRM;
  END;

  -- ---------- TEST 16b (Phase A, E8): Referenz + Waise GENERISCH fuer JEDEN persons[]-Kontext ----------
  -- Ein beliebiger (auch nicht registrierter) Kontext mit facts.persons[] referenziert family-Personen:
  -- unbekannte person_id -> Trigger-RAISE; family-Write, der eine referenzierte Person entfernt -> RAISE.
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_persons_ctx__', 'x', 'lazy', 'x', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','lisa','note','x')))));
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons,0,person_id}', '"ghost"')
    WHERE name = '__test_persons_ctx__';
    RAISE EXCEPTION 'FAIL generic reference: unbekannte person_id im 2. persons-Kontext akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS generic reference [2. persons-Kontext referenziert nur family-Personen: %]', SQLERRM;
  END;
  BEGIN
    UPDATE agent.core_contexts
    SET metadata = jsonb_set(metadata, '{facts,persons}',
        (SELECT jsonb_agg(p) FROM jsonb_array_elements(metadata->'facts'->'persons') p
         WHERE p->>'person_id' <> 'lisa'))
    WHERE name = 'family';
    RAISE EXCEPTION 'FAIL generic orphan: family-Write verwaiste eine Referenz eines 2. persons-Kontexts';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE '%__test_persons_ctx__:lisa%' THEN
      RAISE EXCEPTION 'FAIL generic orphan: Meldung nennt Kontext/Person nicht: %', SQLERRM;
    END IF;
    RAISE NOTICE 'PASS generic orphan [family-Write blockt verwaiste Referenz jedes persons-Kontexts]';
  END;
  -- Typ-Guard: persons als Objekt statt Array -> RAISE (reservierter Core-Form-Key)
  BEGIN
    UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', '{"a":1}')
    WHERE name = '__test_persons_ctx__';
    RAISE EXCEPTION 'FAIL type guard: persons als Objekt akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS type guard [persons muss ein Array sein]';
  END;
  -- per_user-Kontext ('<base>__<pid>') darf kein persons tragen
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__test_pu__', 'per_user', 'own_user_only', 'core')
  ON CONFLICT (context_name) DO UPDATE SET scope = 'per_user';
  BEGIN
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
    VALUES ('__test_pu____erika', 'x', 'lazy', 'x', 'agent', 'core',
            jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika')))));
    RAISE EXCEPTION 'FAIL per_user persons: per_user-Zeile mit persons akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS per_user persons [persons ist eine Haushalts-Form]';
  END;
  -- gespeicherte JSON-nulls bleiben gueltig (null-Loeschung betrifft nur Patch-Keys)
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons,0,note}', 'null')
  WHERE name = '__test_persons_ctx__';
  RAISE NOTICE 'PASS legacy null [gespeichertes JSON-null weiter akzeptiert]';

  -- ---------- TEST 17 (Review: TRUNCATE-Backstop) ----------
  BEGIN
    TRUNCATE agent.core_contexts;
    RAISE EXCEPTION 'FAIL TRUNCATE-Backstop: core_contexts truncated';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    RAISE NOTICE 'PASS TRUNCATE-Backstop [core_contexts: %]', SQLERRM;
  END;


  -- ---------- TEST 18 (Backlog-Bugfix-Runde B5: per_user-Validator-Dispatch + wertfreie Meldung) ----------
  -- Eine per_user-Zeile '<base>__<pid>' muss den Paket-Validator ihres BASIS-Namens laufen lassen (vorher exakter
  -- NEW.name -> nie). Die Meldung traegt keinen Wert (sie erreicht ueber sub_error_notify den Owner).
  CREATE FUNCTION agent.zz_test_pv_validator(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$
    SELECT CASE WHEN (p->>'salary_floor')::numeric < 0 THEN format('salary_floor %s must be >= 0', p->>'salary_floor') END
  $f$;
  CREATE FUNCTION agent.zz_test_reject_all(p jsonb) RETURNS text LANGUAGE sql IMMUTABLE AS $f$ SELECT 'always invalid' $f$;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package) VALUES
    ('__test_pv__', 'per_user', 'own_user_only', 'core'),
    ('__test_pw__', 'per_user', 'own_user_only', 'core'),
    ('__test_pw____sub', 'per_user', 'own_user_only', 'core');
  INSERT INTO core.context_validators (context_name, validate_fn, package) VALUES
    ('__test_pv__', 'agent.zz_test_pv_validator', 'core'),
    ('__test_pw__', 'agent.zz_test_reject_all', 'core');
  BEGIN
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
    VALUES ('__test_pv____erika', 'x', 'lazy', 'x', 'agent', 'core',
            jsonb_build_object('facts', jsonb_build_object('salary_floor', -98765)));
    RAISE EXCEPTION 'FAIL per_user validator: ungueltiger per_user-Fakt akzeptiert (Validator lief nicht)';
  EXCEPTION WHEN check_violation THEN
    IF SQLERRM LIKE '%98765%' THEN
      RAISE EXCEPTION 'FAIL per_user privacy: Meldung traegt den Wert (%)', SQLERRM; END IF;
    IF SQLERRM NOT LIKE '%__test_pv__%' THEN
      RAISE EXCEPTION 'FAIL per_user message: Basis-Name fehlt (%)', SQLERRM; END IF;
    RAISE NOTICE 'PASS per_user validator [Basis-Validator laeuft, Meldung wertfrei: %]', SQLERRM;
  END;
  -- gueltiger per_user-Fakt geht durch
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_pv____erika', 'x', 'lazy', 'x', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('salary_floor', 50000)));
  -- laengster Basis-Name gewinnt: '__test_pw____sub__p1' gehoert zu '__test_pw____sub' (kein Validator), nicht zu
  -- '__test_pw__' (lehnt alles ab)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_pw____sub__p1', 'x', 'lazy', 'x', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('note_key', 'v')));
  RAISE NOTICE 'PASS per_user prefix [laengster Basis-Name gewinnt]';
  -- Altbestand: facts aus der Zeit VOR einer Regel blockieren keinen content-Write (unveraenderte facts werden nicht
  -- neu geprueft), ein facts-Write wird dagegen geprueft.
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('__test_px__', 'per_user', 'own_user_only', 'core');
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_px____erika', 'x', 'lazy', 'x', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('salary_floor', -1)));   -- noch kein Validator registriert
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('__test_px__', 'agent.zz_test_pv_validator', 'core');
  UPDATE agent.core_contexts SET content = 'neue Notiz' WHERE name = '__test_px____erika';
  BEGIN
    UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,note}', '"x"') WHERE name = '__test_px____erika';
    RAISE EXCEPTION 'FAIL per_user legacy: facts-Write auf ungueltigem Altbestand akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS per_user legacy [content-Write ok, facts-Write geprueft]';
  END;
  -- household-Meldung unveraendert (mit Grund)
  BEGIN
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
    VALUES ('__test_hh_msg__', 'x', 'lazy', 'x', 'agent', 'core',
            jsonb_build_object('facts', jsonb_build_object('age', 40)));
    RAISE EXCEPTION 'FAIL household derived: age akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
    IF SQLERRM NOT LIKE 'household facts invalid: key "age"%' THEN
      RAISE EXCEPTION 'FAIL household message: Grund fehlt (%)', SQLERRM; END IF;
    RAISE NOTICE 'PASS household message [Grund bleibt in der Meldung]';
  END;

  -- WP3 Denylist-Muster: Kalenderjahr / Alter / Minderjaehrig-Flag / years_since_ gesperrt, geplante Roh-Alter erlaubt
  DECLARE
    k text;
  BEGIN
    FOREACH k IN ARRAY ARRAY['birth_year', 'retirement_year', 'graduation_year', 'child_age', 'age_years',
                             'partner_age', 'years_since_change', 'is_minor', 'is_adult'] LOOP
      IF agent.fn_validate_household_facts(jsonb_build_object('blk', jsonb_build_object(k, 1)), '__x__') IS NULL THEN
        RAISE EXCEPTION 'FAIL denylist Muster: % nicht gesperrt', k; END IF;
    END LOOP;
    FOREACH k IN ARRAY ARRAY['start_age', 'planned_retirement_age', 'age_from', 'age_to', 'horizon_years',
                             'experience_note', 'page', 'stage', 'years'] LOOP
      IF agent.fn_validate_household_facts(jsonb_build_object('blk', jsonb_build_object(k, 1)), '__x__') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL denylist Muster: Roh-Key % faelschlich gesperrt', k; END IF;
    END LOOP;
    RAISE NOTICE 'PASS denylist Muster [*_year, age, years_since_, is_minor/adult gesperrt; geplante Alter erlaubt]';
  END;

END $$;

ROLLBACK;
