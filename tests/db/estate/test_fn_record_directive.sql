-- tests/db/estate/test_fn_record_directive.sql
-- WS-2: UPSERT-Vertrag des Vorsorge-Dokumente-Registers — NULLS-NOT-DISTINCT-Falle (zwei
-- Haushalts-Records desselben Typs = EIN Eintrag), partielles COALESCE-Update, Fundstellen-
-- Aufloesung in-fn, Enum-Guards + Kind-Reject (erste Live-Nutzung von adults_only) +
-- Sentinel-Pass-Through. Self-contained family-Fixture (owner 111 / partner 222 / child 333,
-- Muster test_fn_check_write_permission); BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r  JSONB;
  v_id BIGINT;
  v_n  INT;
  v_sp BIGINT;
BEGIN
  -- ---------- Fixture: family owner/partner/child (Projektion fuellt agent.persons) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','lena','first_name','Lena','last_name','Beispiel',
                                 'role','partner','birth_date','1985-06-21','telegram_user_id',222),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- ---------- Kind-Reject (adults_only-Backstop, VOR jeder Validierung/jedem Write) ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','333', 'doc_type','testament', 'doc_status','exists'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.directives;
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [child reject]: Write trotz Reject (%)', v_n; END IF;
  RAISE NOTICE 'PASS [Kind-Reject: ok:false + kein Write]';

  -- ---------- Haushalts-Record (owner_person_id leer = NULL) ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'owner_person_id','', 'doc_type','testament', 'doc_status','exists',
      'form','notariell', 'registry','ztr', 'location_note','Aktenordner Buero'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [household create]: %', v_r;
  END IF;
  v_id := (v_r->>'directive_id')::bigint;

  -- ---------- NULLS-NOT-DISTINCT-Falle: zweiter Haushalts-Record desselben Typs = UPDATE ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','222', 'owner_person_id','', 'doc_type','testament', 'doc_status','planned'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'created')::boolean
     OR (v_r->>'directive_id')::bigint <> v_id THEN
    RAISE EXCEPTION 'FAIL [NULLS-Falle UPSERT]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.directives WHERE owner_person_id IS NULL AND doc_type = 'testament';
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [NULLS-Falle]: % Haushalts-Testamente statt 1', v_n; END IF;
  -- Partielles Update: doc_status uebernommen, form/registry/location_note bewahrt (COALESCE).
  PERFORM 1 FROM estate.directives
   WHERE id = v_id AND doc_status = 'planned' AND form = 'notariell'
     AND registry = 'ztr' AND location_note = 'Aktenordner Buero';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht bewahrt/aktualisiert'; END IF;
  RAISE NOTICE 'PASS [NULLS NOT DISTINCT: 2. Haushalts-Record updated statt dupliziert + COALESCE bewahrt]';

  -- ---------- Person-Record = eigene Zeile neben der Haushalts-Zeile ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'owner_person_id','erika', 'doc_type','testament', 'doc_status','exists'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [person create]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.directives WHERE doc_type = 'testament';
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [person vs household]: % Zeilen statt 2', v_n; END IF;
  RAISE NOTICE 'PASS [Person- und Haushalts-Eintrag koexistieren (2 Zeilen)]';

  -- ---------- Enum-/FK-Guards (freundlich, kein RAISE) ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'doc_type','frobnicate', 'doc_status','exists'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%unknown doc_type%' THEN
    RAISE EXCEPTION 'FAIL [invalid doc_type]: %', v_r;
  END IF;
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'doc_type','erbvertrag', 'doc_status','vielleicht'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid doc_status]: %', v_r; END IF;
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'doc_type','erbvertrag', 'doc_status','exists', 'form','muendlich'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid form]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Enum-Guards doc_type/doc_status/form -> ok:false]';

  -- ---------- Fundstellen-Aufloesung in-fn (0 Treffer -> ok:false; Treffer -> FK gesetzt) ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','111', 'doc_type','vorsorgevollmacht', 'doc_status','exists',
      'storage_place_name','GibtsNicht'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%not found%' THEN
    RAISE EXCEPTION 'FAIL [storage not found]: %', v_r;
  END IF;
  INSERT INTO estate.storage_places (name, kind) VALUES ('__test__ Tresor', 'safe') RETURNING id INTO v_sp;
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','222', 'owner_person_id','lena', 'doc_type','vorsorgevollmacht', 'doc_status','exists',
      'storage_place_name','__test__ Tresor', 'authorized_person','Erika Mustermann'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [storage resolve]: %', v_r; END IF;
  PERFORM 1 FROM estate.directives
   WHERE owner_person_id = 'lena' AND doc_type = 'vorsorgevollmacht' AND storage_place_id = v_sp;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [storage resolve]: storage_place_id nicht gesetzt'; END IF;
  RAISE NOTICE 'PASS [storage_place_name: not-found -> ok:false, Treffer -> FK gesetzt]';

  -- ---------- Sentinel-Pass-Through (nicht-numerische chat_id, e2e-Paritaet) ----------
  v_r := estate.fn_record_directive(jsonb_build_object(
      'chat_id','test_e2e_x', 'doc_type','organspendeausweis', 'doc_status','planned'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [sentinel pass-through]: %', v_r; END IF;
  RAISE NOTICE 'PASS [nicht-numerische chat_id -> Pass-Through (Sentinel/Test)]';
END $$;

ROLLBACK;
