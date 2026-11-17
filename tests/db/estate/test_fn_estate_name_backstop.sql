-- tests/db/estate/test_fn_estate_name_backstop.sql
-- Dubletten-Backstop der estate-Anlagen in der fn selbst (nicht nur im Werkzeug): der Probelauf vor der Karte
-- (core.fn_dry_run) lehnt mit den Treffern ab, dieselbe Regel wie der Resolver des Werkzeugs.
BEGIN;

DO $$
DECLARE
  v      JSONB;
  v_fail TEXT[] := ARRAY[]::text[];
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                               'role','owner','birth_date','1980-05-20','telegram_user_id',111)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  PERFORM estate.fn_create_storage_place('{"chat_id":"111","name":"Tresor Keller","kind":"safe"}'::jsonb);
  v := core.fn_dry_run('estate.fn_create_storage_place(jsonb)'::regprocedure, '{"chat_id":"111","name":"Tresor Keller","kind":"safe"}'::jsonb);
  IF (v->>'ok')::boolean OR jsonb_array_length(COALESCE(v->'candidates','[]')) <> 1 THEN v_fail := v_fail || ('E1 Fundstelle: ' || v::text); END IF;

  PERFORM estate.fn_create_contact('{"chat_id":"111","name":"Notariat Linde","role":"notary"}'::jsonb);
  v := core.fn_dry_run('estate.fn_create_contact(jsonb)'::regprocedure, '{"chat_id":"111","name":"Notariat Linde","role":"notary"}'::jsonb);
  IF (v->>'ok')::boolean OR jsonb_array_length(COALESCE(v->'candidates','[]')) <> 1 THEN v_fail := v_fail || ('E2 Kontakt: ' || v::text); END IF;
  --    gleicher Name, andere Rolle bleibt erlaubt (Regel des Resolvers)
  v := core.fn_dry_run('estate.fn_create_contact(jsonb)'::regprocedure, '{"chat_id":"111","name":"Notariat Linde","role":"lawyer"}'::jsonb);
  IF NOT (v->>'ok')::boolean THEN v_fail := v_fail || ('E2b Kontakt andere Rolle: ' || v::text); END IF;

  PERFORM estate.fn_create_digital_account('{"chat_id":"111","owner_person_id":"erika","provider":"Mailhaus","category":"email","username":"e.m@example.org"}'::jsonb);
  v := core.fn_dry_run('estate.fn_create_digital_account(jsonb)'::regprocedure,
                       '{"chat_id":"111","owner_person_id":"erika","provider":"Mailhaus","category":"email","username":"e.m@example.org"}'::jsonb);
  IF (v->>'ok')::boolean OR jsonb_array_length(COALESCE(v->'candidates','[]')) <> 1 THEN v_fail := v_fail || ('E3 Digital-Konto: ' || v::text); END IF;

  PERFORM estate.fn_create_provider_contract('{"chat_id":"111","owner_person_id":"erika","provider":"Stadtwerke Linde","category":"utilities","death_action":"cancel"}'::jsonb);
  v := core.fn_dry_run('estate.fn_create_provider_contract(jsonb)'::regprocedure,
                       '{"chat_id":"111","owner_person_id":"erika","provider":"Stadtwerke Linde","category":"utilities","death_action":"cancel"}'::jsonb);
  IF (v->>'ok')::boolean OR jsonb_array_length(COALESCE(v->'candidates','[]')) <> 1 THEN v_fail := v_fail || ('E4 Vertrag: ' || v::text); END IF;

  PERFORM estate.fn_create_special_asset('{"chat_id":"111","owner_person_id":"erika","asset_type":"vehicle","description":"Kleinwagen blau"}'::jsonb);
  v := core.fn_dry_run('estate.fn_create_special_asset(jsonb)'::regprocedure,
                       '{"chat_id":"111","owner_person_id":"erika","asset_type":"vehicle","description":"Kleinwagen blau"}'::jsonb);
  IF (v->>'ok')::boolean OR jsonb_array_length(COALESCE(v->'candidates','[]')) <> 1 THEN v_fail := v_fail || ('E5 Sonderwert: ' || v::text); END IF;

  -- Rollen-Perspektive: das Werkzeug faehrt den Probelauf unter estate_rw
  SET LOCAL ROLE estate_rw;
  v := core.fn_dry_run('estate.fn_create_storage_place(jsonb)'::regprocedure, '{"chat_id":"111","name":"Tresor Keller","kind":"safe"}'::jsonb);
  RESET ROLE;
  IF v->>'code' IS DISTINCT FROM 'duplicate' THEN v_fail := v_fail || ('E6 estate_rw: ' || v::text); END IF;

  IF cardinality(v_fail) > 0 THEN
    RAISE EXCEPTION 'FAIL estate_name_backstop (% Faelle): %', cardinality(v_fail), array_to_string(v_fail, ' ||| ');
  END IF;
  RAISE NOTICE 'PASS estate_name_backstop [E1-E5]';
END $$;

ROLLBACK;
