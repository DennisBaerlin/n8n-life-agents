-- tests/db/estate/test_estate_directives.sql
-- Estate WS-0a — Dokumente-Register `estate.directives` + Seed-Katalog `estate.directive_types`.
--
-- Prueft die DB-GESETZE des Kern-Registers (Invarianten strukturell, nicht per fn — die Write-fns
-- kommen erst WS-2): (1) der directive_types-Seed traegt die 9 deutschen Vorsorge-Dokumenttypen mit
-- gueltiger Empfehlungsklasse; (2) UNIQUE(owner_person_id, doc_type) NULLS NOT DISTINCT = genau EIN
-- Registereintrag je (Person|Haushalt, Dokumenttyp) — inkl. der NULL-Falle (zwei Haushalts-Testamente
-- waeren ohne NULLS NOT DISTINCT beide einfuegbar, Lektion advisor_plans P0c); (3) CHECK-/FK-Backstops
-- (doc_status/form/registry, doc_type-FK RESTRICT, person-FK); (4) updated_at-Touch-Trigger.
--
-- Fixture: family-Context-Upsert -> Projektions-Trigger fuellt agent.persons (Muster
-- tests/db/career/test_career_person_scoping.sql). BEGIN...ROLLBACK, kein Residual-State.
BEGIN;

DO $$
DECLARE
  v_cnt    int;
  v_denied boolean;
  v_id     bigint;
  v_before timestamptz;
  v_after  timestamptz;
BEGIN
  -- Fixture: 2 Personen (Owner + Partner) via family-Projektion (FK-Ziel agent.persons).
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11'),
        jsonb_build_object('person_id','lena','first_name','Lena','last_name','B','role','partner',
                           'birth_date','1985-06-21','telegram_user_id',222,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- TEST 1: Seed-Katalog — 9 Typen, alle mit gueltiger Empfehlungsklasse (Gesetz = CHECK).
  SELECT count(*) INTO v_cnt FROM estate.directive_types;
  IF v_cnt <> 9 THEN RAISE EXCEPTION 'FAIL [1a] directive_types erwartet 9 Seed-Zeilen, got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM estate.directive_types
  WHERE doc_type IN ('testament','erbvertrag','vorsorgevollmacht','patientenverfuegung','betreuungsverfuegung',
                     'bestattungsverfuegung','sorgerechtsverfuegung','bankvollmacht_transmortal','organspendeausweis');
  IF v_cnt <> 9 THEN RAISE EXCEPTION 'FAIL [1b] directive_types-Schluessel weichen vom Plan-Katalog ab (got % Treffer)', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM estate.directive_types WHERE recommendation = 'essential';
  IF v_cnt < 1 THEN RAISE EXCEPTION 'FAIL [1c] kein essential-Typ im Seed (Gap-Erwartungsmenge waere leer)'; END IF;
  -- Empfehlungsklasse ausserhalb des Enums -> CHECK blockt.
  v_denied := false;
  BEGIN
    INSERT INTO estate.directive_types (doc_type, label, recommendation, ord)
    VALUES ('__test_bad__', 'Bad', 'mandatory', 99);
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1d] recommendation-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [1] directive_types-Seed (9 Typen, Empfehlungsklassen-CHECK)';

  -- TEST 2: UNIQUE(owner_person_id, doc_type) NULLS NOT DISTINCT — die NULL-Falle.
  -- (2a) EIN Haushalts-Testament (owner_person_id NULL, gemeinschaftliche Urkunde) geht.
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status)
  VALUES (NULL, 'testament', 'exists');
  -- (2b) ein ZWEITES Haushalts-Testament -> unique_violation (NULLS NOT DISTINCT greift).
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status)
    VALUES (NULL, 'testament', 'planned');
  EXCEPTION WHEN unique_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2b] zweites Haushalts-Testament nicht geblockt (NULLS-NOT-DISTINCT-Falle)'; END IF;
  -- (2c) person-eigene Eintraege koexistieren mit dem Haushalts-Eintrag UND untereinander.
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('erika', 'testament', 'exists');
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('lena',  'testament', 'planned');
  SELECT count(*) INTO v_cnt FROM estate.directives WHERE doc_type = 'testament';
  IF v_cnt <> 3 THEN RAISE EXCEPTION 'FAIL [2c] erwartet 3 Testament-Zeilen (Haushalt+erika+lena), got %', v_cnt; END IF;
  -- (2d) dieselbe Person derselbe Typ nochmal -> unique_violation.
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('erika', 'testament', 'planned');
  EXCEPTION WHEN unique_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2d] Duplikat (erika, testament) nicht geblockt'; END IF;
  RAISE NOTICE 'PASS [2] UNIQUE NULLS NOT DISTINCT (Haushalt eindeutig, Personen koexistent)';

  -- TEST 3: CHECK-/FK-Backstops.
  -- (3a) doc_status ausserhalb des Enums -> CHECK.
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('erika', 'erbvertrag', 'maybe');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3a] doc_status-CHECK nicht erzwungen'; END IF;
  -- (3b) unbekannter doc_type -> FK auf directive_types blockt (Katalog ist Gesetz).
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('erika', 'poolvertrag', 'exists');
  EXCEPTION WHEN foreign_key_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3b] doc_type-FK nicht erzwungen'; END IF;
  -- (3c) unbekannte Person -> FK auf agent.persons blockt.
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status) VALUES ('ghost', 'erbvertrag', 'exists');
  EXCEPTION WHEN foreign_key_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3c] person-FK nicht erzwungen'; END IF;
  -- (3d) form/registry-Enums.
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, form)
    VALUES ('erika', 'erbvertrag', 'exists', 'muendlich');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3d] form-CHECK nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, registry)
    VALUES ('erika', 'erbvertrag', 'exists', 'handelsregister');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3e] registry-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [3] CHECK-/FK-Backstops (doc_status, doc_type-FK, person-FK, form, registry)';

  -- TEST 4: storage_places-FK RESTRICT — eine Fundstelle mit Dokumenten ist nicht loeschbar.
  INSERT INTO estate.storage_places (name, kind, location) VALUES ('__test_tresor__', 'safe', 'Arbeitszimmer')
  RETURNING id INTO v_id;
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, storage_place_id)
  VALUES ('erika', 'vorsorgevollmacht', 'exists', v_id);
  v_denied := false;
  BEGIN
    DELETE FROM estate.storage_places WHERE id = v_id;
  EXCEPTION WHEN foreign_key_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [4] storage_places-DELETE trotz referenzierendem Dokument nicht geblockt (RESTRICT)'; END IF;
  RAISE NOTICE 'PASS [4] storage_place-FK RESTRICT';

  -- TEST 5: updated_at-Touch-Trigger feuert beim UPDATE.
  -- NOW() ist transaktions-stabil -> ein frischer INSERT + UPDATE truegen im selben BEGIN denselben
  -- Stempel. Daher: INSERT mit RUECKDATIERTEM updated_at (kein Trigger auf INSERT), dann UPDATE ->
  -- der BEFORE-UPDATE-Trigger muss auf NOW() vorziehen.
  INSERT INTO estate.directives (owner_person_id, doc_type, doc_status, updated_at)
  VALUES ('lena', 'vorsorgevollmacht', 'exists', now() - interval '1 day');
  SELECT updated_at INTO v_before FROM estate.directives WHERE owner_person_id = 'lena' AND doc_type = 'vorsorgevollmacht';
  UPDATE estate.directives SET doc_status = 'planned' WHERE owner_person_id = 'lena' AND doc_type = 'vorsorgevollmacht';
  SELECT updated_at INTO v_after FROM estate.directives WHERE owner_person_id = 'lena' AND doc_type = 'vorsorgevollmacht';
  IF v_after <= v_before THEN RAISE EXCEPTION 'FAIL [5] updated_at-Touch-Trigger feuerte nicht (before=%, after=%)', v_before, v_after; END IF;
  RAISE NOTICE 'PASS [5] updated_at-Touch-Trigger';

  RAISE NOTICE 'PASS estate directives (Seed-Katalog + NULLS-NOT-DISTINCT-UNIQUE + CHECK/FK-Backstops + Touch)';
END $$;

ROLLBACK;
