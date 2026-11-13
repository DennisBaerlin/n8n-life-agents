-- tests/db/estate/test_fn_delete_special_asset.sql
-- Sonderfall-Stub-Loeschung (verkauft/abgegeben — Stubs haben keinen Lifecycle-Status;
-- ein verkauftes Fahrzeug muss raus, sonst falsche Checklisten-Tasks im Ereignisfall) — Typ-Filter,
-- not-found = RAISE, Kind-Reject. Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_n INT;
  v_raised BOOLEAN := FALSE;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','kid','first_name','Kim','last_name','Beispiel',
                                 'role','child','birth_date','2012-03-10','telegram_user_id',333)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  INSERT INTO estate.special_assets (asset_type, description) VALUES
      ('vehicle', 'VW Golf'), ('pet', 'Kater Milo');

  -- Kind-Reject:
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','333', 'description','VW Golf'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Delete (exakte Beschreibung):
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111', 'description','VW Golf'));
  IF NOT (v_r->>'ok')::boolean OR v_r->>'action' <> 'deleted' THEN
    RAISE EXCEPTION 'FAIL [delete]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.special_assets;
  IF v_n <> 1 THEN RAISE EXCEPTION 'FAIL [delete]: % Zeilen statt 1', v_n; END IF;
  PERFORM 1 FROM estate.special_assets WHERE asset_type = 'pet';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [delete]: falsche Zeile geloescht'; END IF;
  RAISE NOTICE 'PASS [Delete: genau der richtige Stub weg]';

  -- not-found -> RAISE:
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111', 'description','GibtsNicht'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' NOT IN ('not_found', 'ambiguous') OR NOT (v_r ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL [not-found -> ok:false]: %', v_r; END IF;
  RAISE NOTICE 'PASS [not-found -> ok:false (Probelauf vor der Karte)]';
END $$;

-- Loeschen eines Stubs schliesst seine offenen Fall-Aufgaben (asset:<id>) in derselben Tx: sonst bliebe z. B. "Waffe
-- melden" offen und der Fall schlosse nie automatisch ab. Andere Stubs/Aufgaben bleiben unberuehrt.
DO $$
DECLARE
  v_r JSONB; v_c JSONB; v_case BIGINT; v_id1 BIGINT; v_id2 BIGINT; v_n INT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','hans','first_name','Hans','last_name','Beispiel','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM estate.special_assets;

  v_c := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
           'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
           'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Beispiel-Waffe'),
                                               jsonb_build_object('asset_type','pet','description','Beispiel-Kater'))));
  IF NOT (v_c->>'ok')::boolean THEN RAISE EXCEPTION 'SETUP [E1] %', v_c; END IF;
  v_case := (v_c->>'case_id')::bigint;
  v_id1 := (v_c->'special_asset_ids'->>0)::bigint;
  v_id2 := (v_c->'special_asset_ids'->>1)::bigint;

  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111','description','Beispiel-Waffe'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [E1 delete ok]: %', v_r; END IF;
  IF (v_r->>'tasks_closed')::int <> 1 THEN RAISE EXCEPTION 'FAIL [E1 tasks_closed = 1]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.case_tasks WHERE case_id = v_case AND subject_ref = 'asset:' || v_id1 AND status = 'open';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [E1 Waffen-Aufgabe darf nicht offen bleiben]'; END IF;
  IF (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND subject_ref = 'asset:' || v_id1) <> 'not_applicable' THEN
    RAISE EXCEPTION 'FAIL [E1 Waffen-Aufgabe not_applicable]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM estate.case_tasks WHERE case_id = v_case AND subject_ref = 'asset:' || v_id2 AND status = 'open') THEN
    RAISE EXCEPTION 'FAIL [E1 Aufgabe des anderen Stubs bleibt offen]'; END IF;

  -- ohne Fall-Aufgaben: tasks_closed = 0
  INSERT INTO estate.special_assets (owner_person_id, asset_type, description) VALUES (NULL, 'vehicle', 'Beispiel-Roller');
  v_r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111','description','Beispiel-Roller'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'tasks_closed')::int <> 0 THEN RAISE EXCEPTION 'FAIL [E1 ohne Aufgaben: 0]: %', v_r; END IF;
  RAISE NOTICE 'PASS [E1 Stub-Loeschen schliesst nur seine offenen Aufgaben]';
END $$;

ROLLBACK;
