-- tests/db/estate/test_role_estate_cases.sql
-- Rollen-Perspektive der estate-Werkzeuge rund um Fälle, Vorsorge-Register und Fundstellen: alle fns laufen unter
--   estate_rw (so wie die n8n-Knoten sie aufrufen). Schreib-Werkzeuge mit Karte rufen zuerst den Probelauf
--   core.fn_dry_run (zurückgerollt) und nach dem Tipp die fn direkt; fn_create_case_task (kein HITL) und die
--   Lese-fns (fn_preview_case, fn_resolve_storage_place) direkt. Geprüft wird die echte Wirkung auf die Tabellen
--   (Zahlen/Werte), nicht nur "kein Fehler": fehlende Tabellen-/Sequenz-/EXECUTE-Rechte bricht den Block ab.
BEGIN;

-- Fixture: Haushalt (Erika = Owner, Hans = Partner), erfundene Daten.
DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
    jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
      jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
END $$;

-- Fall-Werkzeuge in Lebenszyklus-Reihenfolge: preview -> (Fall anlegen) -> set_case -> create_case_task -> cancel_case.
DO $$
DECLARE
  r       jsonb;
  v_case  bigint;
  v_event date := core.fn_today() - 10;
  v_know  date := core.fn_today() - 5;
BEGIN
  -- fn_preview_case (Lese-fn, estate_rw): Vorschau eines Todesfalls für Hans, nichts wird geschrieben.
  SET LOCAL ROLE estate_rw;
  r := estate.fn_preview_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
         'event_date', to_char(v_event,'YYYY-MM-DD'),'bundesland','bayern'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'bundesland' <> 'bayern' OR (r->>'total_open')::int <= 0
     OR (SELECT count(*) FROM estate.cases) <> 0 THEN
    RAISE EXCEPTION 'FAIL [fn_preview_case estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_preview_case estate_rw (total_open=%)', r->>'total_open';

  -- Fixture: offener Fall (Superuser).
  r := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
         'event_date', to_char(v_event,'YYYY-MM-DD'),'bundesland','bayern'));
  v_case := (r->>'case_id')::bigint;
  IF v_case IS NULL THEN RAISE EXCEPTION 'FAIL [Fixture create_case]: %', r; END IF;

  -- fn_set_case: Probelauf (zurückgerollt), dann echter Write (Bundesland, Kenntnisdatum, flags).
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_case(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','case_id', v_case,'bundesland','berlin','knowledge_date', to_char(v_know,'YYYY-MM-DD')));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT bundesland FROM estate.cases WHERE id = v_case) <> 'bayern' THEN
    RAISE EXCEPTION 'FAIL [fn_set_case Probelauf estate_rw]: %', r; END IF;
  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_case(jsonb_build_object('chat_id','111','case_id', v_case,'bundesland','berlin',
         'knowledge_date', to_char(v_know,'YYYY-MM-DD'),'flags', jsonb_build_object('tenant', false)));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'total_open')::int <= 0
     OR NOT EXISTS (SELECT 1 FROM estate.cases WHERE id = v_case AND bundesland = 'berlin'
                    AND knowledge_date = v_know AND flags = '{"tenant":false}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL [fn_set_case Write estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_case estate_rw';

  -- fn_create_case_task (kein HITL, direkt): manuelle Aufgabe mit relativer Fälligkeit.
  SET LOCAL ROLE estate_rw;
  r := estate.fn_create_case_task(jsonb_build_object('chat_id','111','case_id', v_case,'title','Blumen bestellen',
         'phase','first_week','due_date','in 3 days'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.case_tasks WHERE id = (r->>'case_task_id')::bigint AND case_id = v_case
                    AND template_key IS NULL AND title = 'Blumen bestellen' AND status_source = 'user'
                    AND due_date = core.fn_today() + 3) THEN
    RAISE EXCEPTION 'FAIL [fn_create_case_task estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_create_case_task estate_rw';

  -- fn_cancel_case: Probelauf (Fall bleibt offen), dann echter Write (cancelled + closed_at).
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_cancel_case(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','case_id', v_case));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT status FROM estate.cases WHERE id = v_case) <> 'open' THEN
    RAISE EXCEPTION 'FAIL [fn_cancel_case Probelauf estate_rw]: %', r; END IF;
  SET LOCAL ROLE estate_rw;
  r := estate.fn_cancel_case(jsonb_build_object('chat_id','111','case_id', v_case));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.cases WHERE id = v_case AND status = 'cancelled' AND closed_at IS NOT NULL) THEN
    RAISE EXCEPTION 'FAIL [fn_cancel_case Write estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_cancel_case estate_rw';
END $$;

-- Fundstellen: Fixture, Umbenennen (set_storage_place), Auflösen (resolve_storage_place).
DO $$
DECLARE
  r      jsonb;
  v_id   bigint;
  v_res  record;
BEGIN
  INSERT INTO estate.storage_places (name, kind, location)
  VALUES ('Ordner Vorsorge', 'folder', 'Büro') RETURNING id INTO v_id;

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_storage_place(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','storage_place_id', v_id,'new_name','Bankschließfach Beispielbank','new_kind','bank_deposit_box'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT name FROM estate.storage_places WHERE id = v_id) <> 'Ordner Vorsorge' THEN
    RAISE EXCEPTION 'FAIL [fn_set_storage_place Probelauf estate_rw]: %', r; END IF;
  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_storage_place(jsonb_build_object('chat_id','111','storage_place_id', v_id,
         'new_name','Bankschließfach Beispielbank','new_kind','bank_deposit_box','access_hint','Schlüssel bei Erika'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.storage_places WHERE id = v_id AND name = 'Bankschließfach Beispielbank'
                    AND kind = 'bank_deposit_box' AND location = 'Büro' AND access_hint = 'Schlüssel bei Erika') THEN
    RAISE EXCEPTION 'FAIL [fn_set_storage_place Write estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_storage_place estate_rw';

  -- fn_resolve_storage_place (Lese-fn): genau ein Treffer -> id, hit_count 1, Kandidat mit Namen.
  SET LOCAL ROLE estate_rw;
  SELECT * INTO v_res FROM estate.fn_resolve_storage_place('Bankschließfach Beispielbank');
  RESET ROLE;
  IF v_res.id IS DISTINCT FROM v_id OR v_res.hit_count <> 1
     OR v_res.candidates->0->>'name' IS DISTINCT FROM 'Bankschließfach Beispielbank' THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_storage_place estate_rw]: id=% hits=% cand=%', v_res.id, v_res.hit_count, v_res.candidates; END IF;
  RAISE NOTICE 'PASS fn_resolve_storage_place estate_rw';
END $$;

-- Vorsorge-Register: record_directive (UPSERT inkl. Fundstellen-Auflösung in der fn) + Bestattungswünsche.
DO $$
DECLARE
  r      jsonb;
  v_sp   bigint;
BEGIN
  INSERT INTO estate.storage_places (name, kind, location)
  VALUES ('Aktenschrank Flur', 'folder', 'Flur') RETURNING id INTO v_sp;

  -- fn_record_directive: Probelauf (nichts bleibt), dann echter UPSERT (neu angelegt, Fundstelle über Namen verknüpft).
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_record_directive(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','owner_person_id','erika','doc_type','testament','doc_status','exists',
           'form','notariell','storage_place_name','Aktenschrank Flur'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM estate.directives WHERE owner_person_id = 'erika') THEN
    RAISE EXCEPTION 'FAIL [fn_record_directive Probelauf estate_rw]: %', r; END IF;
  SET LOCAL ROLE estate_rw;
  r := estate.fn_record_directive(jsonb_build_object('chat_id','111','owner_person_id','erika','doc_type','testament',
         'doc_status','exists','form','notariell','storage_place_name','Aktenschrank Flur'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'created')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.directives WHERE id = (r->>'directive_id')::bigint AND owner_person_id = 'erika'
                    AND doc_type = 'testament' AND doc_status = 'exists' AND form = 'notariell' AND storage_place_id = v_sp) THEN
    RAISE EXCEPTION 'FAIL [fn_record_directive Write estate_rw]: %', r; END IF;
  -- Zweiter Aufruf = UPDATE desselben Eintrags (kein Duplikat), Form bleibt (COALESCE).
  SET LOCAL ROLE estate_rw;
  r := estate.fn_record_directive(jsonb_build_object('chat_id','111','owner_person_id','erika','doc_type','testament',
         'doc_status','planned'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'created')::boolean IS NOT FALSE
     OR (SELECT count(*) FROM estate.directives WHERE owner_person_id = 'erika' AND doc_type = 'testament') <> 1
     OR NOT EXISTS (SELECT 1 FROM estate.directives WHERE owner_person_id = 'erika' AND doc_type = 'testament'
                    AND doc_status = 'planned' AND form = 'notariell') THEN
    RAISE EXCEPTION 'FAIL [fn_record_directive Update estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_record_directive estate_rw';

  -- fn_set_funeral_preferences: Probelauf, dann UPSERT (Anbieter setzt has_prepaid_contract=true).
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_funeral_preferences(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','person_id','erika','burial_type','feuerbestattung'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR EXISTS (SELECT 1 FROM estate.funeral_preferences WHERE person_id = 'erika') THEN
    RAISE EXCEPTION 'FAIL [fn_set_funeral_preferences Probelauf estate_rw]: %', r; END IF;
  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_funeral_preferences(jsonb_build_object('chat_id','111','person_id','erika','burial_type','feuerbestattung',
         'prepaid_contract_provider','Bestattungshaus Muster','wishes','Musik: Ave Maria'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'created')::boolean IS NOT TRUE OR (r->>'has_prepaid_contract')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.funeral_preferences WHERE person_id = 'erika' AND burial_type = 'feuerbestattung'
                    AND has_prepaid_contract IS TRUE AND prepaid_contract_provider = 'Bestattungshaus Muster'
                    AND wishes = 'Musik: Ave Maria') THEN
    RAISE EXCEPTION 'FAIL [fn_set_funeral_preferences Write estate_rw]: %', r; END IF;
  RAISE NOTICE 'PASS fn_set_funeral_preferences estate_rw';
END $$;

ROLLBACK;
