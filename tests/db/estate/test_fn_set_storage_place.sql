-- tests/db/estate/test_fn_set_storage_place.sql
-- WS-2: partielles Fundstellen-Update (Repurpose statt Delete — Fundstellen sind FK-Ziel
-- der directives, RESTRICT) — Rename/kind-Wechsel, kind-Guard, Kind-Reject. Self-contained.
BEGIN;

DO $$
DECLARE
  v_r  JSONB;
  v_id BIGINT;
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

  INSERT INTO estate.storage_places (name, kind, location)
  VALUES ('Ordner Vorsorge', 'folder', 'Buero') RETURNING id INTO v_id;

  -- Kind-Reject:
  v_r := estate.fn_set_storage_place(jsonb_build_object('chat_id','333', 'storage_place_id',v_id, 'location','Keller'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Rename + kind-Wechsel + partielles Update:
  v_r := estate.fn_set_storage_place(jsonb_build_object(
      'chat_id','111', 'storage_place_id',v_id, 'new_name','Bankschliessfach Sparkasse',
      'new_kind','bank_deposit_box', 'access_hint','Schluessel bei Erika'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set]: %', v_r; END IF;
  PERFORM 1 FROM estate.storage_places
   WHERE id = v_id AND name = 'Bankschliessfach Sparkasse' AND kind = 'bank_deposit_box'
     AND location = 'Buero' AND access_hint = 'Schluessel bei Erika';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [Rename/Repurpose + COALESCE bewahrt]';

  -- Guard:
  v_r := estate.fn_set_storage_place(jsonb_build_object('chat_id','111', 'storage_place_id',v_id, 'new_kind','keller'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid new_kind]: %', v_r; END IF;
  RAISE NOTICE 'PASS [kind-Guard -> ok:false]';
END $$;

ROLLBACK;
