-- tests/db/estate/test_fn_create_provider_contract.sql
-- WS-2: Vertrag-Anlage — Happy Path (Person-Zuordnung), Enum-Guards (category/death_action),
-- Pflichtfeld provider, Kind-Reject (adults_only). Self-contained; BEGIN..ROLLBACK.
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

  -- Kind-Reject (VOR jedem Write):
  v_r := estate.fn_create_provider_contract(jsonb_build_object(
      'chat_id','333', 'provider','Stadtwerke', 'category','utilities'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [child reject]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM estate.provider_contracts;
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [child reject]: Write trotz Reject'; END IF;
  RAISE NOTICE 'PASS [Kind-Reject: ok:false + kein Write]';

  -- Happy Path (Person-Zuordnung + death_action):
  v_r := estate.fn_create_provider_contract(jsonb_build_object(
      'chat_id','111', 'owner_person_id','erika', 'provider','Stadtwerke Musterstadt',
      'category','utilities', 'customer_no','KD-4711', 'death_action','cancel',
      'contact_info','0800 123456'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'provider_contract_id') IS NULL THEN
    RAISE EXCEPTION 'FAIL [happy path]: %', v_r;
  END IF;
  PERFORM 1 FROM estate.provider_contracts
   WHERE id = (v_r->>'provider_contract_id')::bigint AND owner_person_id = 'erika'
     AND category = 'utilities' AND customer_no = 'KD-4711' AND death_action = 'cancel';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [happy path]: Zeile nicht wie erwartet gespeichert'; END IF;
  RAISE NOTICE 'PASS [create: Person + Felder gespeichert]';

  -- Guards (freundliche ok:false, kein RAISE):
  v_r := estate.fn_create_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider','', 'category','telecom'));
  IF (v_r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [empty provider]: %', v_r; END IF;
  v_r := estate.fn_create_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider','X', 'category','frobnicate'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid category%' THEN
    RAISE EXCEPTION 'FAIL [invalid category]: %', v_r;
  END IF;
  v_r := estate.fn_create_provider_contract(jsonb_build_object(
      'chat_id','111', 'provider','X', 'category','telecom', 'death_action','explode'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%invalid death_action%' THEN
    RAISE EXCEPTION 'FAIL [invalid death_action]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS [Guards: provider/category/death_action -> ok:false]';
END $$;

ROLLBACK;
