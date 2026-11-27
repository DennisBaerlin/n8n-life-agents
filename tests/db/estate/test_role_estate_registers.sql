-- tests/db/estate/test_role_estate_registers.sql
-- Rollen-Perspektive der Register-Werkzeuge (Kontakte, digitale Konten, Anbieter-Vertraege, Sonderfall-Stubs):
--   estate.fn_{create,set,delete}_{digital_account,provider_contract,special_asset,contact} (ohne create_contact) und
--   estate.fn_resolve_{contact,digital_account,provider_contract,special_asset} laufen unter estate_rw, wie in den
--   Workflow-Knoten (Schreib-fns zuerst als core.fn_dry_run-Probelauf, danach direkt; Resolver direkt).
--   Geprueft wird die echte Wirkung (Zeile geschrieben/geaendert/geloescht, Werte) unter genau dieser Rolle, damit fehlende
--   Rechte auf Tabelle, Sequenz oder Helfer auffallen, die der Superuser-Test nie sieht.
--   Zwischen SET LOCAL ROLE und RESET ROLE steht nur der Aufruf unter Test; Fixture und Assertions laufen als Superuser.
BEGIN;

-- Familien-Fixture (chat_id 111 = Erika, Erwachsene) fuer die Kind-/Erwachsenen-Pruefung der Schreib-fns.
DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('facts', jsonb_build_object(
            'persons', jsonb_build_array(
              jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                 'role','owner','birth_date','1980-05-20','telegram_user_id',111),
              jsonb_build_object('person_id','hans','first_name','Hans','last_name','Beispiel',
                                 'role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
END $$;

-- ===== fn_create_digital_account =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_create_digital_account(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','owner_person_id','erika','provider','Rollen-Mail','category','email',
                            'username','erika@rollen.example','is_key_account','true'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM estate.digital_accounts WHERE provider = 'Rollen-Mail') THEN
    RAISE EXCEPTION 'FAIL [fn_create_digital_account Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_create_digital_account(
         jsonb_build_object('chat_id','111','owner_person_id','erika','provider','Rollen-Mail','category','email',
                            'username','erika@rollen.example','is_key_account','true'));
  RESET ROLE;
  v_id := (r->>'digital_account_id')::bigint;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM estate.digital_accounts
                     WHERE id = v_id AND owner_person_id = 'erika' AND provider = 'Rollen-Mail'
                       AND category = 'email' AND username = 'erika@rollen.example' AND is_key_account) THEN
    RAISE EXCEPTION 'FAIL [fn_create_digital_account Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_create_digital_account estate_rw';
END $$;

-- ===== fn_create_provider_contract =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_create_provider_contract(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','owner_person_id','erika','provider','Rollen-Stadtwerke',
                            'category','utilities','customer_no','KD-4711','death_action','cancel'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM estate.provider_contracts WHERE provider = 'Rollen-Stadtwerke') THEN
    RAISE EXCEPTION 'FAIL [fn_create_provider_contract Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_create_provider_contract(
         jsonb_build_object('chat_id','111','owner_person_id','erika','provider','Rollen-Stadtwerke',
                            'category','utilities','customer_no','KD-4711','death_action','cancel'));
  RESET ROLE;
  v_id := (r->>'provider_contract_id')::bigint;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM estate.provider_contracts
                     WHERE id = v_id AND owner_person_id = 'erika' AND provider = 'Rollen-Stadtwerke'
                       AND category = 'utilities' AND customer_no = 'KD-4711' AND death_action = 'cancel') THEN
    RAISE EXCEPTION 'FAIL [fn_create_provider_contract Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_create_provider_contract estate_rw';
END $$;

-- ===== fn_create_special_asset =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_create_special_asset(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','owner_person_id','erika','asset_type','vehicle',
                            'description','Rollen-Golf MU-ST 123'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM estate.special_assets WHERE description = 'Rollen-Golf MU-ST 123') THEN
    RAISE EXCEPTION 'FAIL [fn_create_special_asset Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_create_special_asset(
         jsonb_build_object('chat_id','111','owner_person_id','erika','asset_type','vehicle',
                            'description','Rollen-Golf MU-ST 123'));
  RESET ROLE;
  v_id := (r->>'special_asset_id')::bigint;
  IF (r->>'ok')::boolean IS NOT TRUE OR v_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM estate.special_assets
                     WHERE id = v_id AND owner_person_id = 'erika' AND asset_type = 'vehicle'
                       AND description = 'Rollen-Golf MU-ST 123') THEN
    RAISE EXCEPTION 'FAIL [fn_create_special_asset Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_create_special_asset estate_rw';
END $$;

-- ===== fn_set_contact =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  INSERT INTO estate.contacts (name, role, phone) VALUES ('Dr. Rollen-Alt', 'physician', '0111') RETURNING id INTO v_id;

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_contact(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','contact_id',v_id,'new_name','Dr. Rollen-Neu','email','praxis@rollen.example'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.contacts WHERE id = v_id AND name = 'Dr. Rollen-Alt') THEN
    RAISE EXCEPTION 'FAIL [fn_set_contact Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_contact(
         jsonb_build_object('chat_id','111','contact_id',v_id,'new_name','Dr. Rollen-Neu','email','praxis@rollen.example'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.contacts
                     WHERE id = v_id AND name = 'Dr. Rollen-Neu' AND role = 'physician'
                       AND phone = '0111' AND email = 'praxis@rollen.example') THEN
    RAISE EXCEPTION 'FAIL [fn_set_contact Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_set_contact estate_rw';
END $$;

-- ===== fn_set_digital_account =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  INSERT INTO estate.digital_accounts (provider, category, username)
  VALUES ('Rollen-Cloud', 'cloud', 'max@rollen.example') RETURNING id INTO v_id;

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_digital_account(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','digital_account_id',v_id,'desired_action','transfer',
                            'is_key_account','yes','legacy_contact_status','configured'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM estate.digital_accounts WHERE id = v_id AND is_key_account) THEN
    RAISE EXCEPTION 'FAIL [fn_set_digital_account Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_digital_account(
         jsonb_build_object('chat_id','111','digital_account_id',v_id,'desired_action','transfer',
                            'is_key_account','yes','legacy_contact_status','configured'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.digital_accounts
                     WHERE id = v_id AND provider = 'Rollen-Cloud' AND username = 'max@rollen.example'
                       AND desired_action = 'transfer' AND is_key_account AND legacy_contact_status = 'configured') THEN
    RAISE EXCEPTION 'FAIL [fn_set_digital_account Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_set_digital_account estate_rw';
END $$;

-- ===== fn_set_provider_contract =====
DO $$
DECLARE
  r jsonb;
  v_id bigint;
BEGIN
  INSERT INTO estate.provider_contracts (provider, category, customer_no)
  VALUES ('Rollen-Telekom', 'telecom', 'KD-1') RETURNING id INTO v_id;

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_set_provider_contract(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','provider_contract_id',v_id,'death_action','cancel','contract_no','V-99'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR EXISTS (SELECT 1 FROM estate.provider_contracts WHERE id = v_id AND contract_no = 'V-99') THEN
    RAISE EXCEPTION 'FAIL [fn_set_provider_contract Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_set_provider_contract(
         jsonb_build_object('chat_id','111','provider_contract_id',v_id,'death_action','cancel','contract_no','V-99'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR NOT EXISTS (SELECT 1 FROM estate.provider_contracts
                     WHERE id = v_id AND provider = 'Rollen-Telekom' AND category = 'telecom'
                       AND customer_no = 'KD-1' AND contract_no = 'V-99' AND death_action = 'cancel') THEN
    RAISE EXCEPTION 'FAIL [fn_set_provider_contract Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_set_provider_contract estate_rw';
END $$;

-- ===== fn_delete_contact =====
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO estate.contacts (name, role) VALUES ('Dr. Rollen-Loesch', 'physician'), ('Dr. Rollen-Loesch', 'lawyer');

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_delete_contact(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','name','Dr. Rollen-Loesch','role','lawyer'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM estate.contacts WHERE name = 'Dr. Rollen-Loesch') <> 2 THEN
    RAISE EXCEPTION 'FAIL [fn_delete_contact Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_delete_contact(jsonb_build_object('chat_id','111','name','Dr. Rollen-Loesch','role','lawyer'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM estate.contacts WHERE name = 'Dr. Rollen-Loesch') <> 1
     OR NOT EXISTS (SELECT 1 FROM estate.contacts WHERE name = 'Dr. Rollen-Loesch' AND role = 'physician') THEN
    RAISE EXCEPTION 'FAIL [fn_delete_contact Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_delete_contact estate_rw';
END $$;

-- ===== fn_delete_digital_account =====
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO estate.digital_accounts (provider, category, username)
  VALUES ('Rollen-Google', 'email', 'erika@rollen.example'), ('Rollen-Google', 'email', 'max@rollen.example');

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_delete_digital_account(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','provider','Rollen-Google','username','max@rollen.example'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM estate.digital_accounts WHERE provider = 'Rollen-Google') <> 2 THEN
    RAISE EXCEPTION 'FAIL [fn_delete_digital_account Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_delete_digital_account(
         jsonb_build_object('chat_id','111','provider','Rollen-Google','username','max@rollen.example'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM estate.digital_accounts WHERE provider = 'Rollen-Google') <> 1
     OR NOT EXISTS (SELECT 1 FROM estate.digital_accounts WHERE username = 'erika@rollen.example') THEN
    RAISE EXCEPTION 'FAIL [fn_delete_digital_account Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_delete_digital_account estate_rw';
END $$;

-- ===== fn_delete_provider_contract =====
DO $$
DECLARE
  r jsonb;
BEGIN
  INSERT INTO estate.provider_contracts (provider, category) VALUES ('Rollen-Anbieter', 'telecom'), ('Rollen-Anbieter', 'media');

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_delete_provider_contract(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','provider','Rollen-Anbieter','category','media'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE
     OR (SELECT count(*) FROM estate.provider_contracts WHERE provider = 'Rollen-Anbieter') <> 2 THEN
    RAISE EXCEPTION 'FAIL [fn_delete_provider_contract Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_delete_provider_contract(
         jsonb_build_object('chat_id','111','provider','Rollen-Anbieter','category','media'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'deleted'
     OR (SELECT count(*) FROM estate.provider_contracts WHERE provider = 'Rollen-Anbieter') <> 1
     OR NOT EXISTS (SELECT 1 FROM estate.provider_contracts WHERE provider = 'Rollen-Anbieter' AND category = 'telecom') THEN
    RAISE EXCEPTION 'FAIL [fn_delete_provider_contract Write estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_delete_provider_contract estate_rw';
END $$;

-- ===== fn_delete_special_asset =====
-- Ohne Fall: Stub weg, tasks_closed = 0. Mit Fall: das Loeschen schliesst die offene Aufgabe des Stubs (UPDATE auf
-- estate.case_tasks) - dieses Recht fehlt dem Superuser-Test nie, estate_rw aber koennte es nicht haben.
DO $$
DECLARE
  r jsonb;
  c jsonb;
  v_case bigint;
  v_id1 bigint;
  v_id2 bigint;
BEGIN
  DELETE FROM estate.special_assets;
  INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', 'Rollen-Golf'), ('pet', 'Rollen-Kater');

  SET LOCAL ROLE estate_rw;
  r := core.fn_dry_run('estate.fn_delete_special_asset(jsonb)'::regprocedure,
         jsonb_build_object('chat_id','111','description','Rollen-Golf'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT count(*) FROM estate.special_assets) <> 2 THEN
    RAISE EXCEPTION 'FAIL [fn_delete_special_asset Probelauf estate_rw]: %', r;
  END IF;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111','description','Rollen-Golf'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'action' <> 'deleted' OR (r->>'tasks_closed')::int <> 0
     OR (SELECT count(*) FROM estate.special_assets) <> 1
     OR NOT EXISTS (SELECT 1 FROM estate.special_assets WHERE asset_type = 'pet') THEN
    RAISE EXCEPTION 'FAIL [fn_delete_special_asset Write estate_rw]: %', r;
  END IF;

  -- Fall mit zwei Stubs (Waffe, Haustier): nur die Aufgabe des geloeschten Stubs wird geschlossen.
  DELETE FROM estate.special_assets;
  c := estate.fn_create_case(jsonb_build_object('chat_id','111','case_type','death','subject_person_id','hans',
         'event_date',(CURRENT_DATE - 2)::text,'bundesland','bayern',
         'special_assets', jsonb_build_array(jsonb_build_object('asset_type','firearm','description','Rollen-Waffe'),
                                             jsonb_build_object('asset_type','pet','description','Rollen-Hamster'))));
  IF (c->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'SETUP [fn_delete_special_asset Fall]: %', c; END IF;
  v_case := (c->>'case_id')::bigint;
  v_id1 := (c->'special_asset_ids'->>0)::bigint;
  v_id2 := (c->'special_asset_ids'->>1)::bigint;

  SET LOCAL ROLE estate_rw;
  r := estate.fn_delete_special_asset(jsonb_build_object('chat_id','111','description','Rollen-Waffe'));
  RESET ROLE;
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'tasks_closed')::int <> 1
     OR EXISTS (SELECT 1 FROM estate.special_assets WHERE id = v_id1)
     OR (SELECT status FROM estate.case_tasks WHERE case_id = v_case AND subject_ref = 'asset:' || v_id1) <> 'not_applicable'
     OR NOT EXISTS (SELECT 1 FROM estate.case_tasks
                     WHERE case_id = v_case AND subject_ref = 'asset:' || v_id2 AND status = 'open') THEN
    RAISE EXCEPTION 'FAIL [fn_delete_special_asset Write mit Fall-Aufgabe estate_rw]: %', r;
  END IF;
  RAISE NOTICE 'PASS fn_delete_special_asset estate_rw';
END $$;

-- ===== fn_resolve_contact (lesend) =====
DO $$
DECLARE
  rr record;
  v_n bigint;
  v_l bigint;
BEGIN
  INSERT INTO estate.contacts (role, name) VALUES ('notary', 'Notarin Rollen');
  INSERT INTO estate.contacts (role, name) VALUES ('notary', 'Doppel Rollen') RETURNING id INTO v_n;
  INSERT INTO estate.contacts (role, name) VALUES ('lawyer', 'Doppel Rollen') RETURNING id INTO v_l;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_contact('Notarin Rollen');
  RESET ROLE;
  IF rr.id IS NULL OR rr.hit_count <> 1 OR rr.candidates->0->>'name' <> 'Notarin Rollen' THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_contact 1 Treffer estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_contact('Doppel Rollen');
  RESET ROLE;
  IF rr.id IS NOT NULL OR rr.hit_count <> 2
     OR (rr.candidates->0->>'id')::bigint <> v_n OR (rr.candidates->1->>'id')::bigint <> v_l THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_contact 2 Treffer estate_rw]: id=%, hit_count=%, candidates=%', rr.id, rr.hit_count, rr.candidates;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_contact('Doppel Rollen', 'lawyer');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_l OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_contact Rollen-Filter estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_contact estate_rw';
END $$;

-- ===== fn_resolve_digital_account (lesend) =====
DO $$
DECLARE
  rr record;
  v_a bigint;
  v_b bigint;
  v_solo bigint;
BEGIN
  INSERT INTO estate.digital_accounts (category, provider, username) VALUES ('email', 'Rollen-Post', 'a.rollen') RETURNING id INTO v_a;
  INSERT INTO estate.digital_accounts (category, provider, username) VALUES ('email', 'Rollen-Post', 'b.rollen') RETURNING id INTO v_b;
  INSERT INTO estate.digital_accounts (category, provider) VALUES ('cloud', 'Rollen-Wolke') RETURNING id INTO v_solo;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_digital_account('Rollen-Wolke');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_solo OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_digital_account 1 Treffer estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_digital_account('Rollen-Post');
  RESET ROLE;
  IF rr.id IS NOT NULL OR rr.hit_count <> 2
     OR (rr.candidates->0->>'id')::bigint <> v_a OR (rr.candidates->1->>'id')::bigint <> v_b THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_digital_account 2 Treffer estate_rw]: id=%, hit_count=%, candidates=%', rr.id, rr.hit_count, rr.candidates;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_digital_account('Rollen-Post', 'b.rollen');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_b OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_digital_account Nutzername-Filter estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_digital_account estate_rw';
END $$;

-- ===== fn_resolve_provider_contract (lesend) =====
DO $$
DECLARE
  rr record;
  v_solo bigint;
  v_power bigint;
  v_phone bigint;
BEGIN
  INSERT INTO estate.provider_contracts (category, provider) VALUES ('other', 'Rollen-Einzel') RETURNING id INTO v_solo;
  INSERT INTO estate.provider_contracts (category, provider) VALUES ('utilities', 'Rollen-Doppel') RETURNING id INTO v_power;
  INSERT INTO estate.provider_contracts (category, provider) VALUES ('telecom', 'Rollen-Doppel') RETURNING id INTO v_phone;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_provider_contract('Rollen-Einzel');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_solo OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_provider_contract 1 Treffer estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_provider_contract('Rollen-Doppel');
  RESET ROLE;
  IF rr.id IS NOT NULL OR rr.hit_count <> 2
     OR (rr.candidates->0->>'id')::bigint <> v_power OR (rr.candidates->1->>'id')::bigint <> v_phone THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_provider_contract 2 Treffer estate_rw]: id=%, hit_count=%, candidates=%', rr.id, rr.hit_count, rr.candidates;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_provider_contract('Rollen-Doppel', 'telecom');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_phone OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_provider_contract Kategorie-Filter estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_provider_contract estate_rw';
END $$;

-- ===== fn_resolve_special_asset (lesend) =====
DO $$
DECLARE
  rr record;
  v_solo bigint;
  v_car bigint;
  v_pet bigint;
BEGIN
  INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', 'Rollen-Einzelstueck') RETURNING id INTO v_solo;
  INSERT INTO estate.special_assets (asset_type, description) VALUES ('vehicle', 'Rollen-Doppel') RETURNING id INTO v_car;
  INSERT INTO estate.special_assets (asset_type, description) VALUES ('pet', 'Rollen-Doppel') RETURNING id INTO v_pet;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_special_asset('Rollen-Einzelstueck');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_solo OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_special_asset 1 Treffer estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_special_asset('Rollen-Doppel');
  RESET ROLE;
  IF rr.id IS NOT NULL OR rr.hit_count <> 2
     OR (rr.candidates->0->>'id')::bigint <> v_car OR (rr.candidates->1->>'id')::bigint <> v_pet THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_special_asset 2 Treffer estate_rw]: id=%, hit_count=%, candidates=%', rr.id, rr.hit_count, rr.candidates;
  END IF;

  SET LOCAL ROLE estate_rw;
  SELECT * INTO rr FROM estate.fn_resolve_special_asset('Rollen-Doppel', 'pet');
  RESET ROLE;
  IF rr.id IS DISTINCT FROM v_pet OR rr.hit_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [fn_resolve_special_asset Typ-Filter estate_rw]: id=%, hit_count=%', rr.id, rr.hit_count;
  END IF;
  RAISE NOTICE 'PASS fn_resolve_special_asset estate_rw';
END $$;

ROLLBACK;
