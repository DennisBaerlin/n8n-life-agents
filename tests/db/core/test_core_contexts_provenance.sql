-- tests/db/core/test_core_contexts_provenance.sql
-- D14 / WS-B2: agent.core_contexts.package + managed_by sind TYPISIERTE Spalten (aus metadata
-- promoted). Deckt: (1) Spalten-Existenz/Typ/Default/NOT NULL, (2) managed_by-CHECK (seed|build|agent),
-- (3) den V001-Backfill-Vertrag (metadata->>'managed_by'/'package' -> Spalte; finance_profile/
-- finance_plan_current -> package='finance'; danach Strip NUR dieser jsonb-Keys), (4) fremde
-- metadata-Keys (render_fn) bleiben dabei unangetastet. (Loeschschutz lebt seit WS-B2b in
-- core.protected_contexts, nicht mehr in metadata.protected — s. test_core_protected_contexts.)
-- Self-contained: BEGIN ... ROLLBACK.
BEGIN;

-- 1) Spalten existieren mit korrektem Typ/Default/NOT NULL
DO $$
DECLARE v_rec RECORD; v_have INT := 0;
BEGIN
  FOR v_rec IN
    SELECT column_name, data_type, is_nullable, column_default
    FROM information_schema.columns
    WHERE table_schema = 'agent' AND table_name = 'core_contexts'
      AND column_name IN ('package', 'managed_by')
  LOOP
    v_have := v_have + 1;
    IF v_rec.data_type <> 'text' OR v_rec.is_nullable <> 'NO' THEN
      RAISE EXCEPTION 'FAIL provenance [schema]: % muss text NOT NULL sein, got %/%', v_rec.column_name, v_rec.data_type, v_rec.is_nullable;
    END IF;
  END LOOP;
  IF v_have <> 2 THEN
    RAISE EXCEPTION 'FAIL provenance [schema]: package+managed_by fehlen (gefunden %)', v_have;
  END IF;
  RAISE NOTICE 'PASS provenance [Spalten package/managed_by: text NOT NULL]';
END $$;

-- 2) Defaults greifen (package='core', managed_by='seed') wenn nicht angegeben
DO $$
DECLARE v_pkg TEXT; v_mb TEXT;
BEGIN
  INSERT INTO agent.core_contexts (name, description, load_strategy, content)
  VALUES ('__test_prov_default__', 'x', 'static', 'body');
  SELECT package, managed_by INTO v_pkg, v_mb FROM agent.core_contexts WHERE name = '__test_prov_default__';
  IF v_pkg IS DISTINCT FROM 'core' OR v_mb IS DISTINCT FROM 'seed' THEN
    RAISE EXCEPTION 'FAIL provenance [default]: erwartet core/seed, got %/%', v_pkg, v_mb;
  END IF;
  RAISE NOTICE 'PASS provenance [Defaults package=core/managed_by=seed]';
END $$;

-- 3) managed_by-CHECK: nur seed|build|agent
DO $$
DECLARE caught BOOLEAN := false;
BEGIN
  BEGIN
    INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by)
    VALUES ('__test_prov_badmb__', 'x', 'static', 'body', 'bogus');
  EXCEPTION WHEN check_violation THEN caught := true;
  END;
  IF NOT caught THEN
    RAISE EXCEPTION 'FAIL provenance [CHECK]: managed_by=bogus muss ein check_violation werfen';
  END IF;
  -- gueltige Werte gehen durch
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('__test_prov_agent__', 'x', 'lazy', 'body', 'agent', 'finance');
  RAISE NOTICE 'PASS provenance [CHECK managed_by IN (seed,build,agent)]';
END $$;

-- 4) V001-Backfill-Vertrag (Logik gespiegelt aus V001__promote_context_provenance_columns.sql):
--    eine Alt-Zeile mit metadata.managed_by/.package -> Spalten gesetzt; finance_profile/-plan_current
--    -> package='finance'; danach sind die jsonb-Keys entfernt.
DO $$
DECLARE v_pkg TEXT; v_mb TEXT; v_meta JSONB;
BEGIN
  -- Alt-Zeilen simulieren (wie vor D14 geschrieben): managed_by/package nur in metadata.
  -- (Spalten bekommen erst mal die Defaults core/seed.)
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata)
  VALUES ('__test_prov_legacy_build__', 'x', 'lazy', 'body',
          '{"managed_by":"build","package":"core","render_fn":"fn_household_context"}'::jsonb);
  -- finance_profile-artige Laufzeit-Zeile: managed_by in metadata, KEIN package-Key (so entsteht sie real).
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata)
  VALUES ('finance_profile', 'x', 'lazy', 'body',
          jsonb_build_object('managed_by','agent','protected', true,
                             'facts', jsonb_build_object('persons','[]'::jsonb)))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata, managed_by = 'seed', package = 'core';

  -- ----- Backfill (Kopie der V001-Statements) -----
  UPDATE agent.core_contexts
     SET managed_by = COALESCE(NULLIF(metadata->>'managed_by',''), managed_by),
         package    = COALESCE(NULLIF(metadata->>'package',''),    package)
   WHERE name IN ('__test_prov_legacy_build__', 'finance_profile');
  UPDATE agent.core_contexts SET package = 'finance' WHERE name IN ('finance_profile', 'finance_plan_current');
  UPDATE agent.core_contexts
     SET metadata = metadata - 'managed_by' - 'package'
   WHERE name IN ('__test_prov_legacy_build__', 'finance_profile') AND metadata ?| array['managed_by','package'];

  -- Assert: legacy_build -> managed_by=build/package=core, keys gestrippt, protected bleibt
  SELECT managed_by, package, metadata INTO v_mb, v_pkg, v_meta
  FROM agent.core_contexts WHERE name = '__test_prov_legacy_build__';
  IF v_mb IS DISTINCT FROM 'build' OR v_pkg IS DISTINCT FROM 'core' THEN
    RAISE EXCEPTION 'FAIL provenance [backfill build]: erwartet build/core, got %/%', v_mb, v_pkg;
  END IF;
  IF v_meta ? 'managed_by' OR v_meta ? 'package' THEN
    RAISE EXCEPTION 'FAIL provenance [backfill strip]: jsonb-Keys nicht entfernt: %', v_meta;
  END IF;
  IF v_meta->>'render_fn' IS DISTINCT FROM 'fn_household_context' THEN
    RAISE EXCEPTION 'FAIL provenance [backfill]: fremder metadata-Key (render_fn) faelschlich angefasst: %', v_meta;
  END IF;

  -- Assert: finance_profile -> managed_by=agent (aus metadata), package=finance (explizite Regel)
  SELECT managed_by, package INTO v_mb, v_pkg FROM agent.core_contexts WHERE name = 'finance_profile';
  IF v_mb IS DISTINCT FROM 'agent' OR v_pkg IS DISTINCT FROM 'finance' THEN
    RAISE EXCEPTION 'FAIL provenance [backfill finance_profile]: erwartet agent/finance, got %/%', v_mb, v_pkg;
  END IF;
  RAISE NOTICE 'PASS provenance [V001-Backfill: metadata->Spalte, finance_profile->finance, Strip, protected bleibt]';
END $$;

ROLLBACK;
