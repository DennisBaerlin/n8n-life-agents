-- tests/db/estate/test_fn_set_contact.sql
-- WS-2: partielles Kontakt-Update — Rename via new_name, Rollen-Guard, Kind-Reject.
-- Self-contained; BEGIN..ROLLBACK.
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

  INSERT INTO estate.contacts (name, role, phone)
  VALUES ('Dr. Alt', 'physician', '0111') RETURNING id INTO v_id;

  -- Kind-Reject:
  v_r := estate.fn_set_contact(jsonb_build_object('chat_id','333', 'contact_id',v_id, 'phone','0222'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Rename + partielles Update (phone bewahrt bei Nicht-Sendung):
  v_r := estate.fn_set_contact(jsonb_build_object(
      'chat_id','111', 'contact_id',v_id, 'new_name','Dr. Neu', 'email','praxis@dr-neu.de'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [set]: %', v_r; END IF;
  PERFORM 1 FROM estate.contacts
   WHERE id = v_id AND name = 'Dr. Neu' AND role = 'physician' AND phone = '0111' AND email = 'praxis@dr-neu.de';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [partial update]: Felder nicht wie erwartet'; END IF;
  RAISE NOTICE 'PASS [Rename via new_name + COALESCE bewahrt]';

  -- Guard:
  v_r := estate.fn_set_contact(jsonb_build_object('chat_id','111', 'contact_id',v_id, 'new_role','friseur'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [invalid new_role]: %', v_r; END IF;
  RAISE NOTICE 'PASS [Rollen-Guard -> ok:false]';
END $$;

ROLLBACK;
