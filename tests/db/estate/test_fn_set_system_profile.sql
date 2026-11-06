-- tests/db/estate/test_fn_set_system_profile.sql
-- WS-5: System-Steckbrief-UPSERT (Haushalts-Singleton). Prueft: Kind-Reject (adults_only-Backstop),
-- Happy-Create + Post-State, partielles UPSERT-Update (nicht gesendet = unveraendert), Singleton-
-- Invariante (CHECK verbietet 2. scope-Wert; PK verbietet 2. Zeile). Self-contained; BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_r      JSONB;
  v_raised BOOLEAN;
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

  -- ---------- TEST 1: Kind-Reject (adults_only-Backstop; nur Erwachsene) ----------
  v_r := estate.fn_set_system_profile(jsonb_build_object(
      'chat_id','333', 'backup_key_location','Tresor'));
  IF (v_r->>'ok')::boolean OR v_r->>'reason' NOT LIKE '%adults_only%' THEN
    RAISE EXCEPTION 'FAIL [1 child reject]: %', v_r; END IF;
  IF EXISTS (SELECT 1 FROM estate.system_profile) THEN
    RAISE EXCEPTION 'FAIL [1 child reject schrieb doch]'; END IF;
  RAISE NOTICE 'PASS [1] Kind-Reject (kein Write)';

  -- ---------- TEST 2: Happy-Create + Post-State ----------
  v_r := estate.fn_set_system_profile(jsonb_build_object(
      'chat_id','111',
      'backup_key_location','Umschlag "lifeagents backup key" im Tresor Buero',
      'system_location','Debian-LXC auf Proxmox im Keller',
      'admin_access','Neffe Max, Tel 0170-1234567',
      'restore_hint','lifeagents backup restore; Anleitung im Ordner "IT" im Sekretaer'));
  IF NOT (v_r->>'ok')::boolean OR NOT (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [2 happy create]: %', v_r; END IF;
  PERFORM 1 FROM estate.system_profile
   WHERE scope = 'household'
     AND backup_key_location LIKE '%Tresor Buero%'
     AND system_location LIKE '%Proxmox%';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [2 Zeile nicht gespeichert]'; END IF;
  RAISE NOTICE 'PASS [2] Happy-Create + Post-State created=true';

  -- ---------- TEST 3: partielles UPSERT-Update (nur notes; Bestand bewahrt) ----------
  v_r := estate.fn_set_system_profile(jsonb_build_object(
      'chat_id','111', 'notes','Router-Passwort steht NICHT hier (nur Fundort-Verweise)'));
  IF NOT (v_r->>'ok')::boolean OR (v_r->>'created')::boolean THEN
    RAISE EXCEPTION 'FAIL [3 upsert update]: %', v_r; END IF;
  PERFORM 1 FROM estate.system_profile
   WHERE scope = 'household'
     AND backup_key_location LIKE '%Tresor Buero%'   -- bewahrt (nicht gesendet)
     AND notes LIKE '%Fundort-Verweise%';
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [3 partial update: Bestand nicht bewahrt]'; END IF;
  IF (SELECT count(*) FROM estate.system_profile) <> 1 THEN
    RAISE EXCEPTION 'FAIL [3 UPSERT erzeugte 2. Zeile]'; END IF;
  RAISE NOTICE 'PASS [3] partielles Update (created=false, Bestand bewahrt, weiterhin 1 Zeile)';

  -- ---------- TEST 4: Singleton-Invariante strukturell (CHECK + PK) ----------
  -- (4a) CHECK verbietet einen anderen scope-Wert.
  v_raised := FALSE;
  BEGIN
    INSERT INTO estate.system_profile (scope, notes) VALUES ('backup', 'x');
  EXCEPTION WHEN check_violation THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [4a CHECK erlaubte fremden scope]'; END IF;
  -- (4b) PK verbietet eine 2. household-Zeile.
  v_raised := FALSE;
  BEGIN
    INSERT INTO estate.system_profile (scope, notes) VALUES ('household', 'y');
  EXCEPTION WHEN unique_violation THEN v_raised := TRUE;
  END;
  IF NOT v_raised THEN RAISE EXCEPTION 'FAIL [4b PK erlaubte 2. Zeile]'; END IF;
  RAISE NOTICE 'PASS [4] Singleton strukturell (CHECK scope=household + PK)';
END $$;

ROLLBACK;
