-- tests/db/core/test_core_services.sql
-- WS-B6: core.services traegt eine package-Spalte (Sibling-Konsistenz mit core.context_validators/
-- core.protected_contexts: Audit/Uninstall-Scope) und wird vom generischen _seed_services materialisiert.
-- Deckt das deterministisch testbare SCHEMA (die bash-Seeder-Logik deckt die Substrat-Reset-Verifikation):
--   (1) Tabellen-Form: PK(name) + Spalten name/workflow_id/description/package/updated_at;
--   (2) package NOT NULL DEFAULT 'core' (Default greift; expliziter NULL bricht);
--   (3) trg_services_touch schreibt updated_at bei UPDATE fort (Trigger feuert, anders als die beiden
--       Geschwister-Registries, deren Touch-fn alphabetisch spaeter definiert wird -> bewusst KEIN Trigger);
--   (4) Paket-Tool-Services (paperless Phase 2): permission NOT NULL DEFAULT 'owner_only' (fail-closed) + CHECK
--       auf die drei Stufen; Namens-Praefix-CHECK — Core-Zeilen unqualifiziert, Nicht-Core-Zeilen MUESSEN
--       '<package>:<alias>' heissen (der Vermittler trifft nie ein fremdes Paket-Ziel unter falschem Praefix).
-- db_test hat KEIN seed_data -> self-contained: BEGIN ... ROLLBACK.
BEGIN;

-- 1) Tabellen-Form: PK(name) + die fuenf Spalten (insb. die neue package-Spalte)
DO $$
DECLARE
  missing text;
BEGIN
  IF to_regclass('core.services') IS NULL THEN
    RAISE EXCEPTION 'FAIL services [schema]: Tabelle core.services fehlt';
  END IF;
  SELECT string_agg(c, ', ') INTO missing
  FROM unnest(ARRAY['name','workflow_id','description','package','permission','updated_at']) AS c
  WHERE NOT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema='core' AND table_name='services' AND column_name=c);
  IF missing IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL services [columns]: fehlende Spalte(n): %', missing;
  END IF;

  -- PK auf name
  INSERT INTO core.services (name, workflow_id, package) VALUES ('__test_svc_pk__', 'wf1', 'core');
  BEGIN
    INSERT INTO core.services (name, workflow_id, package) VALUES ('__test_svc_pk__', 'wf2', 'core');
    RAISE EXCEPTION 'FAIL services [PK]: Doppel-Insert desselben name akzeptiert';
  EXCEPTION WHEN unique_violation THEN NULL;   -- erwartet
  END;
  RAISE NOTICE 'PASS services [Tabelle + Spalten + PK(name)]';
END $$;

-- 2) package: NOT NULL DEFAULT 'core'
DO $$
DECLARE
  v_pkg text;
BEGIN
  -- Default greift, wenn package nicht angegeben wird
  INSERT INTO core.services (name, workflow_id) VALUES ('__test_svc_default__', 'wf');
  SELECT package INTO v_pkg FROM core.services WHERE name='__test_svc_default__';
  IF v_pkg IS DISTINCT FROM 'core' THEN
    RAISE EXCEPTION 'FAIL services [package-default]: erwartet ''core'', bekam %', COALESCE(quote_literal(v_pkg), 'NULL');
  END IF;

  -- expliziter NULL bricht (NOT NULL)
  BEGIN
    INSERT INTO core.services (name, workflow_id, package) VALUES ('__test_svc_null__', 'wf', NULL);
    RAISE EXCEPTION 'FAIL services [package-notnull]: NULL-package akzeptiert';
  EXCEPTION WHEN not_null_violation THEN NULL;   -- erwartet
  END;
  RAISE NOTICE 'PASS services [package NOT NULL DEFAULT ''core'']';
END $$;

-- 3) trg_services_touch: UPDATE schreibt updated_at fort (Trigger ueberschreibt einen alten Wert mit now()).
--    Innerhalb EINER Transaktion ist now()=transaction_timestamp() konstant -> wir setzen updated_at
--    kuenstlich in die Vergangenheit und pruefen, dass der Trigger es bei UPDATE auf die Txn-Zeit hebt.
DO $$
DECLARE
  v_after timestamptz;
BEGIN
  INSERT INTO core.services (name, workflow_id, package, updated_at)
  VALUES ('__test_svc_touch__', 'wf1', 'core', TIMESTAMPTZ '2000-01-01 00:00:00+00');
  UPDATE core.services SET workflow_id='wf2' WHERE name='__test_svc_touch__';
  SELECT updated_at INTO v_after FROM core.services WHERE name='__test_svc_touch__';
  IF v_after <= TIMESTAMPTZ '2001-01-01 00:00:00+00' THEN
    RAISE EXCEPTION 'FAIL services [touch]: updated_at bei UPDATE nicht fortgeschrieben (blieb %)', v_after;
  END IF;
  RAISE NOTICE 'PASS services [trg_services_touch schreibt updated_at fort]';
END $$;

-- 4) permission (fail-closed Default + CHECK) + Namens-Praefix-CHECK
DO $$
DECLARE
  v_perm text;
BEGIN
  INSERT INTO core.services (name, workflow_id) VALUES ('__test_svc_perm__', 'wf');
  SELECT permission INTO v_perm FROM core.services WHERE name='__test_svc_perm__';
  IF v_perm IS DISTINCT FROM 'owner_only' THEN
    RAISE EXCEPTION 'FAIL services [permission-default]: erwartet ''owner_only'', bekam %', COALESCE(quote_literal(v_perm), 'NULL');
  END IF;
  BEGIN
    INSERT INTO core.services (name, workflow_id, permission) VALUES ('__test_svc_perm_bad__', 'wf', 'everyone');
    RAISE EXCEPTION 'FAIL services [permission-check]: fremde Stufe ''everyone'' akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- die drei gueltigen Stufen
  INSERT INTO core.services (name, workflow_id, package, permission) VALUES
    ('__test_pkg__:a', 'wf', '__test_pkg__', 'all_members'),
    ('__test_pkg__:b', 'wf', '__test_pkg__', 'adults_only'),
    ('__test_pkg__:c', 'wf', '__test_pkg__', 'owner_only');
  RAISE NOTICE 'PASS services [permission DEFAULT owner_only + CHECK 3 Stufen]';

  -- Nicht-Core-Zeile ohne eigenes Praefix -> bricht
  BEGIN
    INSERT INTO core.services (name, workflow_id, package) VALUES ('search_documents', 'wf', '__test_pkg__');
    RAISE EXCEPTION 'FAIL services [prefix]: unqualifizierte Nicht-Core-Zeile akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Nicht-Core-Zeile mit FREMDEM Praefix -> bricht
  BEGIN
    INSERT INTO core.services (name, workflow_id, package) VALUES ('finance:x', 'wf', '__test_pkg__');
    RAISE EXCEPTION 'FAIL services [prefix]: fremdes Praefix akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  -- Core-Zeile mit Doppelpunkt -> bricht (Core bleibt unqualifiziert)
  BEGIN
    INSERT INTO core.services (name, workflow_id, package) VALUES ('core:web_search', 'wf', 'core');
    RAISE EXCEPTION 'FAIL services [prefix]: qualifizierte Core-Zeile akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS services [Namens-Praefix-CHECK: core unqualifiziert, Paket = <package>:<alias>]';
END $$;

ROLLBACK;
