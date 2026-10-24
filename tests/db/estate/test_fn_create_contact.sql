-- tests/db/estate/test_fn_create_contact.sql
-- WS-2: Schluessel-Kontakt-Anlage — Happy Path, Rollen-Guard, Kind-Reject; mehrere Kontakte
-- derselben Rolle sind legitim (kein UNIQUE auf role). Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r JSONB;
  v_n INT;
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
  v_r := estate.fn_create_contact(jsonb_build_object(
      'chat_id','333', 'name','Dr. Muster', 'role','physician'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Kind-Reject]';

  -- Happy Path + zweiter Kontakt derselben Rolle (legitim):
  v_r := estate.fn_create_contact(jsonb_build_object(
      'chat_id','111', 'name','Notariat Dr. Muster', 'role','notary',
      'organization','Notariat Musterstadt', 'phone','0123 456789'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [happy path]: %', v_r; END IF;
  v_r := estate.fn_create_contact(jsonb_build_object(
      'chat_id','111', 'name','Tante Inge', 'role','trusted_person'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [2. Kontakt]: %', v_r; END IF;
  v_r := estate.fn_create_contact(jsonb_build_object(
      'chat_id','111', 'name','Nachbar Klaus', 'role','trusted_person'));
  IF NOT (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [2x trusted_person]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM estate.contacts WHERE role = 'trusted_person';
  IF v_n <> 2 THEN RAISE EXCEPTION 'FAIL [kein UNIQUE auf role]: % statt 2', v_n; END IF;
  RAISE NOTICE 'PASS [create: mehrere Kontakte je Rolle legitim]';

  -- Guards:
  v_r := estate.fn_create_contact(jsonb_build_object('chat_id','111', 'name','', 'role','notary'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [empty name]: %', v_r; END IF;
  v_r := estate.fn_create_contact(jsonb_build_object('chat_id','111', 'name','X', 'role','friseur'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid role%' THEN
    RAISE EXCEPTION 'FAIL [invalid role]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Guards: name/role -> ok:false]';
END $$;

ROLLBACK;
