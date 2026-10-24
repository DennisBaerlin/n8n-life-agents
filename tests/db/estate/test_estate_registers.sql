-- tests/db/estate/test_estate_registers.sql
-- Estate WS-0a — CHECK-/PK-Backstops der uebrigen Register-Tabellen (provider_contracts,
-- digital_accounts, contacts, person_records, funeral_preferences, storage_places, special_assets).
--
-- Die Write-fns kommen erst WS-2 — hier wird bewiesen, dass die INVARIANTEN bereits DB-strukturell
-- gelten (Constraint = Gesetz, fn = spaeter nur freundliche {ok:false}-Meldung). Nicht-offensichtlich:
-- (a) digital_accounts.seed_backup_location ist CHECK-GEKOPPELT an category='crypto' (ein Seed-Fundort
--     an einem Nicht-Krypto-Konto ist ein Datenfehler); die Spalte haelt NUR den FUNDORT-Verweis,
--     nie die Seed-Phrase selbst (Owner-Entscheid 2: Geheimnisse NIE im System).
-- (b) person_records erzwingt die deutschen Stammdaten-Formate (Steuer-ID ^\d{11}$,
--     RV-Nr ^\d{8}[A-Z]\d{3}$) als CHECK — das LLM validiert nie selbst.
--
-- Fixture: family-Projektion (agent.persons). BEGIN...ROLLBACK, kein Residual-State.
BEGIN;

DO $$
DECLARE
  v_denied boolean;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f',
    jsonb_build_object('managed_by','agent','protected', true,
      'facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner',
                           'birth_date','1980-05-20','telegram_user_id',111,'as_of','2026-06-11')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- TEST 1: provider_contracts — category-/death_action-CHECKs; death_action NULL = offener Gap (erlaubt).
  INSERT INTO estate.provider_contracts (owner_person_id, category, provider, death_action)
  VALUES ('erika', 'telecom', 'Telekom', 'cancel');
  INSERT INTO estate.provider_contracts (owner_person_id, category, provider)
  VALUES (NULL, 'utilities', 'Stadtwerke');   -- Haushalt + death_action NULL (Gap) sind legitim
  v_denied := false;
  BEGIN
    INSERT INTO estate.provider_contracts (category, provider) VALUES ('timeshare', 'X');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1a] provider_contracts.category-CHECK nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    INSERT INTO estate.provider_contracts (category, provider, death_action) VALUES ('telecom', 'X', 'ignore');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [1b] provider_contracts.death_action-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [1] provider_contracts (category/death_action, NULL-Gap erlaubt)';

  -- TEST 2: digital_accounts — Krypto-Seed-Kopplung + Enums.
  -- (2a) seed_backup_location an category='crypto' -> ok (nur der FUNDORT, nie die Phrase).
  INSERT INTO estate.digital_accounts (owner_person_id, category, provider, seed_backup_location)
  VALUES ('erika', 'crypto', 'Ledger', 'Metallplatte im Bankschliessfach');
  -- (2b) seed_backup_location an einem NICHT-Krypto-Konto -> CHECK blockt (Kopplung).
  v_denied := false;
  BEGIN
    INSERT INTO estate.digital_accounts (owner_person_id, category, provider, seed_backup_location)
    VALUES ('erika', 'email', 'GMX', 'Tresor');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2b] seed_backup_location ohne crypto-Kategorie nicht geblockt (CHECK-Kopplung)'; END IF;
  -- (2c) category-/desired_action-/legacy_contact_status-Enums.
  v_denied := false;
  BEGIN
    INSERT INTO estate.digital_accounts (category, provider) VALUES ('metaverse', 'X');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2c] digital_accounts.category-CHECK nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    INSERT INTO estate.digital_accounts (category, provider, desired_action) VALUES ('email', 'GMX', 'sell');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2d] digital_accounts.desired_action-CHECK nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    INSERT INTO estate.digital_accounts (category, provider, legacy_contact_status) VALUES ('social', 'FB', 'maybe');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [2e] digital_accounts.legacy_contact_status-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [2] digital_accounts (Krypto-Seed-Kopplung, Enums)';

  -- TEST 3: contacts — role-CHECK; mehrere trusted_person-Zeilen erlaubt (kein UNIQUE auf role).
  INSERT INTO estate.contacts (role, name) VALUES ('notary', 'Dr. Muster');
  INSERT INTO estate.contacts (role, name) VALUES ('trusted_person', 'Maria A');
  INSERT INTO estate.contacts (role, name) VALUES ('trusted_person', 'Ben B');
  v_denied := false;
  BEGIN
    INSERT INTO estate.contacts (role, name) VALUES ('influencer', 'X');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [3] contacts.role-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [3] contacts (role-CHECK, Mehrfach-trusted_person)';

  -- TEST 4: person_records — 1 Zeile je Person (PK) + deutsche Stammdaten-Format-CHECKs.
  INSERT INTO estate.person_records (person_id, tax_id, pension_insurance_no, health_insurance_type)
  VALUES ('erika', '12345678901', '15070649C103', 'gkv');
  v_denied := false;
  BEGIN
    INSERT INTO estate.person_records (person_id) VALUES ('erika');
  EXCEPTION WHEN unique_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [4a] person_records-PK (1 Zeile je Person) nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    UPDATE estate.person_records SET tax_id = '1234567890' WHERE person_id = 'erika';   -- 10 Stellen
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [4b] tax_id-Format-CHECK (11 Ziffern) nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    UPDATE estate.person_records SET pension_insurance_no = '15X70649C103' WHERE person_id = 'erika';
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [4c] pension_insurance_no-Format-CHECK nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    UPDATE estate.person_records SET health_insurance_type = 'privat' WHERE person_id = 'erika';
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [4d] health_insurance_type-CHECK (gkv|pkv) nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [4] person_records (PK je Person, Steuer-ID-/RV-Nr-/GKV-PKV-CHECKs)';

  -- TEST 5: funeral_preferences — 1 Zeile je Person (PK) + burial_type-CHECK.
  INSERT INTO estate.funeral_preferences (person_id, burial_type, wishes)
  VALUES ('erika', 'feuerbestattung', 'Urnenbeisetzung im Familiengrab');
  v_denied := false;
  BEGIN
    INSERT INTO estate.funeral_preferences (person_id) VALUES ('erika');
  EXCEPTION WHEN unique_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [5a] funeral_preferences-PK (1 Zeile je Person) nicht erzwungen'; END IF;
  v_denied := false;
  BEGIN
    UPDATE estate.funeral_preferences SET burial_type = 'weltraum' WHERE person_id = 'erika';
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [5b] burial_type-CHECK nicht erzwungen'; END IF;
  RAISE NOTICE 'PASS [5] funeral_preferences (PK je Person, burial_type-CHECK)';

  -- TEST 6: storage_places kind-CHECK + special_assets asset_type-CHECK (geschlossene Condition-Liste).
  INSERT INTO estate.storage_places (name, kind) VALUES ('Ordner Buero', 'folder');
  v_denied := false;
  BEGIN
    INSERT INTO estate.storage_places (name, kind) VALUES ('X', 'cloud');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [6a] storage_places.kind-CHECK nicht erzwungen'; END IF;
  INSERT INTO estate.special_assets (owner_person_id, asset_type, description)
  VALUES ('erika', 'vehicle', 'VW Golf, Kennzeichen XX-YY 123');
  v_denied := false;
  BEGIN
    INSERT INTO estate.special_assets (asset_type, description) VALUES ('yacht', 'X');
  EXCEPTION WHEN check_violation THEN v_denied := true; END;
  IF NOT v_denied THEN RAISE EXCEPTION 'FAIL [6b] special_assets.asset_type-CHECK nicht erzwungen (geschlossene Condition-Liste)'; END IF;
  RAISE NOTICE 'PASS [6] storage_places/special_assets (kind-/asset_type-CHECKs)';

  RAISE NOTICE 'PASS estate registers (CHECK-/PK-Backstops aller WS-0a-Register)';
END $$;

ROLLBACK;
