-- tests/db/estate/test_fn_create_storage_place.sql
-- WS-2: Fundstellen-Anlage — Happy Path, kind-Guard, Kind-Reject; access_hint ist ein
-- Fundort-VERWEIS (Inhalt haerten Description/Prompt, nicht die DB). Self-contained.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
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

  -- Kind-Reject:
  v_r := estate.fn_create_storage_place(jsonb_build_object(
      'chat_id','333', 'name','Tresor', 'kind','safe'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path:
  v_r := estate.fn_create_storage_place(jsonb_build_object(
      'chat_id','111', 'name','Tresor Arbeitszimmer', 'kind','safe',
      'location','Arbeitszimmer, hinter dem Buecherregal',
      'access_hint','Schluessel im Sekretaer, oberste Schublade'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'storage_place_id') IS NULL THEN
    RAISE EXCEPTION 'FAIL [happy path]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.storage_places
   WHERE id = (v_r->>'storage_place_id')::bigint AND kind = 'safe' AND owner_person_id IS NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [happy path]: Zeile nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [create: Haushalts-Fundstelle gespeichert]';

  -- Guards:
  v_r := estate.fn_create_storage_place(jsonb_build_object('chat_id','111', 'name','', 'kind','safe'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [empty name]: %', v_r; END IF;
  v_r := estate.fn_create_storage_place(jsonb_build_object('chat_id','111', 'name','X', 'kind','keller'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid kind%' THEN
    RAISE EXCEPTION 'FAIL [invalid kind]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Guards: name/kind -> ok:false]';
END $$;

ROLLBACK;
