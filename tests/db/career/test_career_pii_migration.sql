-- tests/db/career/test_career_pii_migration.sql
-- P0b: prueft die EINMALIGE Daten-Migration career:V001 (Bestands-Career-PII haushaltsweit -> per_user-Suffix).
-- Da V-Migrationen gegated laufen (nicht im BEGIN/ROLLBACK-Testpfad), repliziert dieser Test die V001-RENAME-
-- Logik 1:1 (Owner-pid aus family.facts.persons[] WHERE role='owner', UPDATE name, per-Kontext-Skip) und
-- assertet: (1) Basis -> '<base>__<owner>', Basis weg, managed_by/package erhalten; (2) no-op ohne Owner;
-- (3) no-op wenn die Ziel-Zeile schon existiert (Re-Run-Sicherheit). Self-contained: BEGIN ... ROLLBACK.
BEGIN;

-- Wiederverwendbare Kopie der V001-RENAME-Logik (identisch zur Migration).
CREATE OR REPLACE FUNCTION pg_temp.run_career_v001() RETURNS void LANGUAGE plpgsql AS $$
DECLARE v_owner TEXT; v_base TEXT;
BEGIN
  SELECT pp->>'person_id' INTO v_owner
  FROM agent.core_contexts c, jsonb_array_elements(COALESCE(c.metadata->'facts'->'persons','[]'::jsonb)) pp
  WHERE c.name='family' AND pp->>'role'='owner' LIMIT 1;
  IF v_owner IS NULL THEN RETURN; END IF;
  FOREACH v_base IN ARRAY ARRAY['career_profile','career_preferences'] LOOP
    IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name=v_base)
       AND NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name=v_base||'__'||v_owner) THEN
      UPDATE agent.core_contexts SET name=v_base||'__'||v_owner WHERE name=v_base;
    END IF;
  END LOOP;
END $$;

-- ---------- TEST 1: Bestands-Basis-Zeilen -> Owner-suffigiert ----------
DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('family','fix','static','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-01-01')))), 'agent','core'),
         ('career_profile','fix','lazy','P', jsonb_build_object('facts', jsonb_build_object('current_title','Dev')), 'agent','career'),
         ('career_preferences','fix','lazy','Q', jsonb_build_object('facts', jsonb_build_object('salary_floor',70000)), 'agent','career')
  ON CONFLICT (name) DO UPDATE SET metadata=EXCLUDED.metadata, managed_by=EXCLUDED.managed_by, package=EXCLUDED.package;

  PERFORM pg_temp.run_career_v001();

  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile__erika'
                 AND metadata->'facts'->>'current_title'='Dev' AND managed_by='agent' AND package='career') THEN
    RAISE EXCEPTION 'FAIL [1]: career_profile nicht nach __erika migriert / Spalten verloren';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_preferences__erika') THEN
    RAISE EXCEPTION 'FAIL [1]: career_preferences nicht nach __erika migriert';
  END IF;
  IF EXISTS (SELECT 1 FROM agent.core_contexts WHERE name IN ('career_profile','career_preferences')) THEN
    RAISE EXCEPTION 'FAIL [1]: Basis-Zeile nach Migration noch vorhanden';
  END IF;
  RAISE NOTICE 'PASS [1] V001 Migration [Basis -> __erika, Basis weg, managed_by/package erhalten]';

  -- Re-Run (Idempotenz): Basis weg -> no-op, suffigierte Zeile bleibt unveraendert
  PERFORM pg_temp.run_career_v001();
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile__erika') THEN
    RAISE EXCEPTION 'FAIL [1b]: Re-Run hat die suffigierte Zeile beruehrt'; END IF;
  RAISE NOTICE 'PASS [1b] Re-Run no-op (Basis weg)';
END $$;

-- ---------- TEST 2: kein Owner -> no-op ----------
DO $$
BEGIN
  DELETE FROM agent.core_contexts WHERE name LIKE 'career_%' OR name='family';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package)
  VALUES ('career_profile','fix','lazy','P','agent','career');
  PERFORM pg_temp.run_career_v001();   -- keine family/Owner -> skip
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile') THEN
    RAISE EXCEPTION 'FAIL [2]: ohne Owner darf NICHT migriert werden (Basis muss bleiben)';
  END IF;
  RAISE NOTICE 'PASS [2] kein Owner -> no-op (Basis bleibt)';
END $$;

-- ---------- TEST 3: Ziel-Zeile existiert schon -> per-Kontext-Skip (kein Konflikt) ----------
DO $$
BEGIN
  DELETE FROM agent.core_contexts WHERE name LIKE 'career_%' OR name='family';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, metadata, managed_by, package)
  VALUES ('family','fix','static','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
            jsonb_build_object('person_id','erika','role','owner','first_name','E','last_name','M','birth_date','1980-01-01')))), 'agent','core'),
         ('career_profile','fix','lazy','BASE','{}'::jsonb,'agent','career'),
         ('career_profile__erika','fix','lazy','EXISTING','{}'::jsonb,'agent','career')  -- Ziel existiert schon
  ON CONFLICT (name) DO NOTHING;
  PERFORM pg_temp.run_career_v001();
  -- Skip: die bestehende __erika bleibt (EXISTING), die Basis bleibt unangetastet (kein UNIQUE-Konflikt)
  IF (SELECT content FROM agent.core_contexts WHERE name='career_profile__erika') IS DISTINCT FROM 'EXISTING' THEN
    RAISE EXCEPTION 'FAIL [3]: bestehende Ziel-Zeile wurde ueberschrieben'; END IF;
  IF NOT EXISTS (SELECT 1 FROM agent.core_contexts WHERE name='career_profile') THEN
    RAISE EXCEPTION 'FAIL [3]: Basis-Zeile haette beim Ziel-existiert-Skip bleiben muessen'; END IF;
  RAISE NOTICE 'PASS [3] Ziel existiert -> per-Kontext-Skip (kein Ueberschreiben, kein Konflikt)';
END $$;

ROLLBACK;
