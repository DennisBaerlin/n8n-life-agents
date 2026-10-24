-- tests/db/core/test_core_protected_contexts.sql
-- WS-B2b: paket-deklarierter Löschschutz via core.protected_contexts (Kubernetes-Finalizer-Muster).
-- Deckt: (1) Tabellen-Form + PK(context_name); (2) registry-getriebener BEFORE-DELETE-Schutz
-- (registrierter Name -> DELETE blockt; UPDATE bleibt erlaubt; Registry-Eintrag entfernt -> löschbar);
-- (3) nicht-registrierter Context bleibt frei löschbar (Schutz opt-in via Registry); (4) TRUNCATE-Backstop.
-- db_test hat KEIN seed_data -> der Test seedet core.protected_contexts SELBST (wie test_core_context_validators).
-- Self-contained: BEGIN ... ROLLBACK.
BEGIN;

-- 1) Tabellen-Form: PK auf context_name
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='core' AND table_name='protected_contexts') THEN
    RAISE EXCEPTION 'FAIL protected_contexts [schema]: Tabelle core.protected_contexts fehlt';
  END IF;
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('__test_pc_pk__', 'core');
  BEGIN
    INSERT INTO core.protected_contexts (context_name, package) VALUES ('__test_pc_pk__', 'finance');
    RAISE EXCEPTION 'FAIL protected_contexts [PK]: Doppel-Insert desselben context_name akzeptiert';
  EXCEPTION WHEN unique_violation THEN NULL;   -- erwartet
  END;
  RAISE NOTICE 'PASS protected_contexts [Tabelle + PK(context_name)]';
END $$;

-- 2) Registry-getriebener Löschschutz: registrierter Context -> DELETE blockt; UPDATE erlaubt;
--    Registry-Eintrag entfernt (= Finalizer/Uninstall) -> löschbar.
DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__test_pc_guarded__', 'x', 'lazy', 'body');
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('__test_pc_guarded__', 'finance');

  BEGIN
    DELETE FROM agent.core_contexts WHERE name = '__test_pc_guarded__';
    RAISE EXCEPTION 'FAIL protected_contexts [guard]: DELETE eines registrierten Contexts akzeptiert';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;   -- erwartet: Protect-Trigger blockt
  END;

  -- UPDATE bleibt erlaubt (Trigger ist BEFORE DELETE, nicht UPDATE)
  UPDATE agent.core_contexts SET content = 'updated' WHERE name = '__test_pc_guarded__';
  IF (SELECT content FROM agent.core_contexts WHERE name='__test_pc_guarded__') IS DISTINCT FROM 'updated' THEN
    RAISE EXCEPTION 'FAIL protected_contexts [update]: UPDATE eines geschützten Contexts muss erlaubt bleiben';
  END IF;

  -- Finalizer entfernen -> jetzt löschbar (das ist der einzige Lösch-Pfad: Uninstall/Host)
  DELETE FROM core.protected_contexts WHERE context_name = '__test_pc_guarded__';
  DELETE FROM agent.core_contexts WHERE name = '__test_pc_guarded__';
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='__test_pc_guarded__') THEN
    RAISE EXCEPTION 'FAIL protected_contexts [unguard]: nach Registry-Entfernung muss DELETE durchgehen';
  END IF;
  RAISE NOTICE 'PASS protected_contexts [registriert=blockt, UPDATE ok, entregistriert=löschbar (Finalizer)]';
END $$;

-- 3) Nicht-registrierter Context bleibt frei löschbar (Schutz ist opt-in via Registry)
DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__test_pc_free__', 'x', 'lazy', 'body');
  DELETE FROM agent.core_contexts WHERE name = '__test_pc_free__';
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='__test_pc_free__') THEN
    RAISE EXCEPTION 'FAIL protected_contexts [free]: nicht-registrierter Context fälschlich geschützt';
  END IF;
  RAISE NOTICE 'PASS protected_contexts [nicht-registriert -> löschbar]';
END $$;

-- 4) TRUNCATE-Backstop (Statement-Level; row-BEFORE-DELETE feuert bei TRUNCATE nicht)
DO $$
BEGIN
  BEGIN
    TRUNCATE agent.core_contexts CASCADE;
    RAISE EXCEPTION 'FAIL protected_contexts [truncate]: TRUNCATE core_contexts nicht geblockt';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;   -- erwartet: trg_core_contexts_no_truncate
  END;
  RAISE NOTICE 'PASS protected_contexts [TRUNCATE-Backstop core_contexts]';
END $$;

-- 5) P0b suffix-aware Schutz: die suffigierte per_user-PII '<protected_base>__<pid>' einer LEBENDEN Person
--    ist geschuetzt (sonst verloere ein per_user-Rename die Schutz-Bindung); nach Person-Entfernung purgebar.
DO $$
BEGIN
  -- family: Owner + lebendes Mitglied
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata)
  VALUES ('family','fix','lazy',E'## fam', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','owner_p','first_name','O','last_name','P','role','owner','birth_date','1980-01-01'),
            jsonb_build_object('person_id','liveperson','first_name','L','last_name','P','role','partner','birth_date','1990-01-01')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- per_user-Basis, in BEIDEN Registries (protected + scope=per_user)
  INSERT INTO core.protected_contexts (context_name, package) VALUES ('test_pc_peruser','career')
  ON CONFLICT (context_name) DO NOTHING;
  INSERT INTO core.context_scopes (context_name, scope, write_permission, package)
  VALUES ('test_pc_peruser','per_user','own_user_only','career')
  ON CONFLICT (context_name) DO UPDATE SET scope='per_user';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('test_pc_peruser__liveperson','x','lazy','b'),
         ('test_pc_peruser__owner_p','x','lazy','b'),
         ('test_pc_peruser__ghost','x','lazy','b')   -- pid 'ghost' NICHT in family
  ON CONFLICT (name) DO NOTHING;

  -- (A) lebendes Mitglied -> geschuetzt
  BEGIN
    DELETE FROM agent.core_contexts WHERE name='test_pc_peruser__liveperson';
    RAISE EXCEPTION 'FAIL pc-peruser [A]: DELETE der PII einer lebenden Person akzeptiert';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  -- (B) Owner -> geschuetzt
  BEGIN
    DELETE FROM agent.core_contexts WHERE name='test_pc_peruser__owner_p';
    RAISE EXCEPTION 'FAIL pc-peruser [B]: DELETE der Owner-PII akzeptiert';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  -- (C) pid NICHT in family -> NICHT geblockt (purgebar; das ist der Person-Purge-Pfad NACH dem Remove)
  DELETE FROM agent.core_contexts WHERE name='test_pc_peruser__ghost';
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_pc_peruser__ghost') THEN
    RAISE EXCEPTION 'FAIL pc-peruser [C]: PII einer NICHT-lebenden Person muss purgebar sein';
  END IF;
  -- (D) Person aus family entfernen -> ihre PII jetzt purgebar (komponiert mit Person-Purge)
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}',
            jsonb_build_array(jsonb_build_object('person_id','owner_p','first_name','O','last_name','P','role','owner','birth_date','1980-01-01')))
    WHERE name='family';
  DELETE FROM agent.core_contexts WHERE name='test_pc_peruser__liveperson';
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='test_pc_peruser__liveperson') THEN
    RAISE EXCEPTION 'FAIL pc-peruser [D]: nach Person-Entfernung muss die PII purgebar sein';
  END IF;
  RAISE NOTICE 'PASS protected_contexts [P0b suffix-aware: lebende Person/Owner geschuetzt, entfernte/fremde purgebar]';
END $$;

ROLLBACK;
