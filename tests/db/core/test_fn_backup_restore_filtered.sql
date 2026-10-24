-- tests/db/core/test_fn_backup_restore_filtered.sql
-- Phase 4b: core.fn_backup_restore_filtered stellt die ZWEI zeilen-gefilterten geteilten
-- agent-Tabellen wieder her, die pg_restore (Bulk) nicht zeilengenau behandeln kann:
--   * agent.core_contexts (managed_by='agent' = PII: family/finance_profile/financial_planning)
--     -> UPDATE-statt-DELETE (Protect-Trigger blockt DELETE), family VOR den persons[]-Kontexten
--        (bidirektionaler Validator), Phase-0 (deren Live-persons leeren NUR fuer Kontexte, die das
--        Bundle mitbringt — seit Phase A generisch, TEST 4).
--   * agent.monitor_triggers (origin='user') -> DELETE origin='user' (observations CASCADE)
--     + Fresh-id-Insert (kein UNIQUE(domain,lower(label))-Bruch gegen bestehende user-Zeilen).
-- Atomar via die aufrufende TX (SECURITY INVOKER, RAISE -> Rollback). Getestet in BEGIN..ROLLBACK.
BEGIN;

DO $$
DECLARE
  v_payload   JSONB;
  v_result    JSONB;
  v_cc        JSONB;
  v_mt        JSONB;
  v_old_trig  INT;
BEGIN
  -- ============================================================
  -- Fixtures: Live-DB-Vorzustand (wie nach einem frischen Install: family-Skelett +
  -- ein VORHANDENER user-Trigger mit demselben (domain,label) wie im "Bundle" = UNIQUE-Falle).
  -- db_test hat kein seed_data -> Registry-Zeilen + family selbst seeden.
  -- ============================================================
  -- family (managed+protected) LIVE, mit Erika + Lisa
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('family', 'live fixture', NULL, 'lazy', E'## Family\nLive body.', 'agent', 'core',
          jsonb_build_object('render_fn','fn_household_context',
            'facts', jsonb_build_object(
              'persons', jsonb_build_array(
                jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                                   'role','owner','birth_date','1980-05-20','as_of','2026-06-11')),
              'household', jsonb_build_object('shared_finances', true))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, managed_by = EXCLUDED.managed_by, package = EXCLUDED.package;
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('family', 'core') ON CONFLICT DO NOTHING;
  -- finance_profile LIVE mit einer Person, die das Bundle (s.u.) NICHT mehr kennt -> ohne Phase-0
  -- wuerde der family-Restore (nur erika) den Validator gegen die Live-finance_profile-Referenz brechen.
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('finance_profile', 'live fixture', NULL, 'lazy', 'Live finance profile.', 'agent', 'finance',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','steuerklasse',1)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, managed_by = EXCLUDED.managed_by, package = EXCLUDED.package;
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('finance_profile', 'finance') ON CONFLICT DO NOTHING;
  -- ein VORHANDENER user-Trigger mit (domain='general', label='__rt watch') -> Bundle traegt denselben
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, check_interval, origin)
  VALUES ('general', '__rt watch', 'recurring_info', 'none', interval '30 days', 'user')
  RETURNING id INTO v_old_trig;
  -- ein core-Trigger (origin='core') muss den Restore UEBERLEBEN (nur user-Zeilen werden gewipt)
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, check_interval, origin)
  VALUES ('general', '__rt core seed', 'recurring_info', 'none', interval '30 days', 'core')
  ON CONFLICT DO NOTHING;

  -- ============================================================
  -- "Bundle"-Payload: gefilterte Zeilen wie der CLI-Export sie liefert
  --   core_contexts: family (NUR erika) + finance_profile (NUR erika) + ein NEUER managed Context
  --   monitor_triggers: ein user-Trigger mit demselben (domain,label) wie der Live-Trigger
  -- ============================================================
  v_cc := jsonb_build_array(
    jsonb_build_object('name','family','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content',E'## Family\nRestored body.','managed_by','agent','package','core',
      'metadata', jsonb_build_object('render_fn','fn_household_context',
        'facts', jsonb_build_object(
          'persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann',
                               'role','owner','birth_date','1980-05-20','as_of','2026-06-11')),
          'household', jsonb_build_object('shared_finances', true)))),
    jsonb_build_object('name','finance_profile','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content','Restored finance profile.','managed_by','agent','package','finance',
      'metadata', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','steuerklasse',3)))))
  );
  -- monitor-Payload realistisch wie der CLI-Export: VOLLE Zeile(n) via to_jsonb (alle Spalten inkl.
  -- NOT-NULL-Defaults wie warn_days_before — jsonb_populate_recordset wendet KEINE Spalten-Defaults an,
  -- daher muss das Bundle vollstaendig sein; pg_dump/\copy liefert das so). Selber (domain,label) wie der
  -- Live-Trigger -> testet die UNIQUE-Kollisions-Vermeidung (Wipe origin='user' VOR Fresh-id-Insert).
  SELECT jsonb_agg(to_jsonb(t)) INTO v_mt FROM agent.monitor_triggers t WHERE t.origin = 'user';
  v_payload := jsonb_build_object('agent.core_contexts', v_cc, 'agent.monitor_triggers', v_mt);

  -- ============================================================
  -- TEST 1: Restore laeuft sauber durch (Protect-Trigger blockt NICHT, Validator-Order haelt)
  -- ============================================================
  v_result := core.fn_backup_restore_filtered(v_payload);
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL restore_filtered [ok]: %', v_result;
  END IF;

  -- M1: family ueberlebt (per UPDATE ersetzt, nie geloescht) + neuer Content drin
  IF (SELECT content FROM agent.core_contexts WHERE name = 'family') NOT LIKE '%Restored body.%' THEN
    RAISE EXCEPTION 'FAIL restore_filtered [family nicht per UPDATE ersetzt]';
  END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name = 'finance_profile') NOT LIKE '%Restored finance profile.%' THEN
    RAISE EXCEPTION 'FAIL restore_filtered [finance_profile nicht ersetzt]';
  END IF;
  -- M1: direkter DELETE auf family bleibt geblockt (Protect-Trigger intakt)
  BEGIN
    DELETE FROM agent.core_contexts WHERE name = 'family';
    RAISE EXCEPTION 'FAIL restore_filtered [DELETE-Protection: family loeschbar trotz Registry]';
  EXCEPTION WHEN OTHERS THEN NULL;  -- erwartet: Trigger blockt
  END;

  -- M3: genau EIN user-Trigger '__rt watch' (alter gewipt, neuer fresh-id) -> kein UNIQUE-Bruch
  IF (SELECT COUNT(*) FROM agent.monitor_triggers WHERE origin='user' AND label='__rt watch') <> 1 THEN
    RAISE EXCEPTION 'FAIL restore_filtered [monitor user-Trigger count != 1]: %',
      (SELECT COUNT(*) FROM agent.monitor_triggers WHERE origin='user' AND label='__rt watch');
  END IF;
  -- Fresh-id: der wiederhergestellte Trigger traegt eine NEUE id (alter gewipt)
  IF EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE id = v_old_trig) THEN
    RAISE EXCEPTION 'FAIL restore_filtered [monitor: alte user-id % nicht gewipt]', v_old_trig;
  END IF;
  -- core-Trigger ueberlebt (nur user gewipt)
  IF NOT EXISTS (SELECT 1 FROM agent.monitor_triggers WHERE origin='core' AND label='__rt core seed') THEN
    RAISE EXCEPTION 'FAIL restore_filtered [core-Trigger faelschlich gewipt]';
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [M1 family UPDATE+Protect, M2 Order/Phase-0, M3 monitor fresh-id/UNIQUE]';

  -- ============================================================
  -- TEST 2: Counts in der Rueckgabe
  -- ============================================================
  IF (v_result->>'core_contexts')::int <> 2 OR (v_result->>'monitor_triggers')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL restore_filtered [counts]: %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [Counts: core_contexts=2, monitor_triggers=1]';

  -- ============================================================
  -- TEST 3: leeres/teilweises Payload ist tolerant (kein Key -> kein Wipe/Insert)
  -- ============================================================
  v_result := core.fn_backup_restore_filtered('{}'::jsonb);
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL restore_filtered [empty payload]: %', v_result;
  END IF;
  -- family unangetastet, user-Trigger NICHT gewipt (kein monitor-Key im Payload)
  IF (SELECT COUNT(*) FROM agent.monitor_triggers WHERE origin='user' AND label='__rt watch') <> 1 THEN
    RAISE EXCEPTION 'FAIL restore_filtered [empty payload hat monitor-Zeilen veraendert]';
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [leeres Payload: kein Wipe ohne Key]';
END $$;

-- ============================================================
-- TEST 4 (Phase A): Phase 0 GENERISCH fuer jeden persons[]-Kontext (nicht nur finance_profile)
--   Live: family {erika, tom} + ein 2. persons-Kontext, der tom referenziert. Bundle: family NUR {erika} +
--   eine AELTERE Fassung des 2. Kontexts OHNE persons. Ohne generisches Phase 0 blockte die Live-Referenz auf
--   tom den family-Restore (Waisen-Pruefung); die Bedingung haengt an der LIVE-Zeile, nicht an der Bundle-Zeile.
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
BEGIN
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-05-20'),
      jsonb_build_object('person_id','tom','first_name','Tom','last_name','Mustermann','role','child','birth_date','2015-01-01')))
  WHERE name = 'family';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_persons_ctx__', 'live', 'lazy', 'live body', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','tom','note','x')))));

  v_result := core.fn_backup_restore_filtered(jsonb_build_object('agent.core_contexts', jsonb_build_array(
    jsonb_build_object('name','family','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content','## Family','managed_by','agent','package','core',
      'metadata', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner','birth_date','1980-05-20'))))),
    jsonb_build_object('name','__test_persons_ctx__','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content','old body','managed_by','agent','package','core','metadata','{}'::jsonb))));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL restore_filtered [generic phase 0]: %', v_result;
  END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name = '__test_persons_ctx__') IS DISTINCT FROM 'old body' THEN
    RAISE EXCEPTION 'FAIL restore_filtered [generic phase 0]: 2. Kontext nicht ersetzt';
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [Phase 0 generisch: Live-Referenz eines 2. persons-Kontexts blockt den Restore nicht]';
END $$;

-- ============================================================
-- TEST 5: Backup von VOR der Sprach-Normierung (core:V027) — family traegt Freitext-Sprachen
--   ('Deutsch', 'Korean', 'fr'). Der Restore normalisiert sie (agent.fn_normalize_person_languages) statt am
--   Validator (language nur aus core.ui_languages) zu scheitern: Owner -> de, Mitglied ko, Unbekanntes faellt weg.
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_p      JSONB;
BEGIN
  v_result := core.fn_backup_restore_filtered(jsonb_build_object('agent.core_contexts', jsonb_build_array(
    jsonb_build_object('name','family','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content','## Family','managed_by','agent','package','core',
      'metadata', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner',
                           'birth_date','1980-05-20','language','Deutsch'),
        jsonb_build_object('person_id','mina','first_name','Mina','last_name','Mustermann','role','partner',
                           'birth_date','1985-01-01','language','Korean'),
        jsonb_build_object('person_id','tom','first_name','Tom','last_name','Mustermann','role','child',
                           'birth_date','2015-01-01','language','fr'))))))));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL restore_filtered [Alt-Sprachen]: %', v_result;
  END IF;
  SELECT metadata->'facts'->'persons' INTO v_p FROM agent.core_contexts WHERE name = 'family';
  IF v_p->0->>'language' IS DISTINCT FROM 'de' OR v_p->1->>'language' IS DISTINCT FROM 'ko'
     OR (v_p->2) ? 'language' THEN
    RAISE EXCEPTION 'FAIL restore_filtered [Alt-Sprachen nicht normalisiert]: %', v_p;
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [Alt-Backup mit Freitext-Sprachen wird normalisiert]';
END $$;

-- ============================================================
-- TEST 6: Bundle mit unbekannter Persona ('pirate', z. B. aus einer neueren Version) bzw. 'neutral' — der
--   Restore verwirft nur diesen Key, bekannte Personas bleiben, der family-Restore scheitert nicht am Validator.
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_p      JSONB;
BEGIN
  v_result := core.fn_backup_restore_filtered(jsonb_build_object('agent.core_contexts', jsonb_build_array(
    jsonb_build_object('name','family','description','restored','agent_name',NULL,'load_strategy','lazy',
      'content','## Family','managed_by','agent','package','core',
      'metadata', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
        jsonb_build_object('person_id','erika','first_name','Erika','last_name','Mustermann','role','owner',
                           'birth_date','1980-05-20','language','de','persona','butler'),
        jsonb_build_object('person_id','mina','first_name','Mina','last_name','Mustermann','role','partner',
                           'birth_date','1985-01-01','language','ko','persona','pirate'),
        jsonb_build_object('person_id','tom','first_name','Tom','last_name','Mustermann','role','child',
                           'birth_date','2015-01-01','persona','neutral'))))))));
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL restore_filtered [unbekannte Persona]: %', v_result;
  END IF;
  SELECT metadata->'facts'->'persons' INTO v_p FROM agent.core_contexts WHERE name = 'family';
  IF v_p->0->>'persona' IS DISTINCT FROM 'butler' OR (v_p->1) ? 'persona' OR (v_p->2) ? 'persona'
     OR v_p->1->>'language' IS DISTINCT FROM 'ko' THEN
    RAISE EXCEPTION 'FAIL restore_filtered [Persona nicht bereinigt]: %', v_p;
  END IF;
  RAISE NOTICE 'PASS fn_backup_restore_filtered [unbekannte/neutral-Persona verworfen, bekannte bleibt]';
END $$;

ROLLBACK;
