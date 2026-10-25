-- tests/db/core/test_v032_derived_keys_cleanup.sql
-- core:V032 (ECHTE Datei, zweimal): Bestand mit nun gesperrten abgeleiteten Keys (*_year, Alter, is_minor …)
--   wird bereinigt — Keys rekursiv aus metadata.facts entfernt, Wert als Zeile in die Prosa VOR "## Gelernt";
--   erlaubte Roh-Keys (start_age, age_from) und saubere Kontexte bleiben unberuehrt; zweiter Lauf = no-op.
--   Der Fixture-Insert umgeht den Fakten-Trigger (er wuerde die gesperrten Keys heute abweisen = Altbestand).
BEGIN;

ALTER TABLE agent.core_contexts DISABLE TRIGGER trg_validate_household_facts;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('__t_v032_dirty__', 't', NULL, 'lazy', E'## Prosa\n\n## Gelernt\n\n- Notiz', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object(
          'persons', jsonb_build_array(jsonb_build_object('person_id', 'p1', 'child_age', 7, 'start_age', 60)),
          'glidepath', jsonb_build_object('phases', jsonb_build_array(jsonb_build_object('age_from', 50, 'is_minor', FALSE))),
          'retirement_year', 2050,
          '_meta', jsonb_build_object('last_confirmed_at', '2026-01-01')))),
       ('__t_v032_clean__', 't', NULL, 'lazy', 'sauber', 'agent', 'core',
        jsonb_build_object('facts', jsonb_build_object('start_age', 60, 'horizon_years', 20)));
ALTER TABLE agent.core_contexts ENABLE TRIGGER trg_validate_household_facts;

\ir ../../../packages/core/db/migrations/V032__derived_keys_cleanup_onboarding_skipped_at.sql
\ir ../../../packages/core/db/migrations/V032__derived_keys_cleanup_onboarding_skipped_at.sql

DO $$
DECLARE
  f jsonb;
  c text;
BEGIN
  SELECT metadata->'facts', content INTO f, c FROM agent.core_contexts WHERE name = '__t_v032_dirty__';
  IF f ? 'retirement_year' OR f->'persons'->0 ? 'child_age' OR f#>'{glidepath,phases,0}' ? 'is_minor' THEN
    RAISE EXCEPTION 'FAIL [gesperrte Keys nicht entfernt: %]', f; END IF;
  IF (f->'persons'->0->>'start_age')::int IS DISTINCT FROM 60 OR (f#>>'{glidepath,phases,0,age_from}')::int IS DISTINCT FROM 50
     OR f->'_meta'->>'last_confirmed_at' IS DISTINCT FROM '2026-01-01' THEN
    RAISE EXCEPTION 'FAIL [erlaubte Roh-Keys/_meta veraendert: %]', f; END IF;
  IF c NOT LIKE '%retirement_year = 2050%' OR c NOT LIKE '%persons[0].child_age = 7%'
     OR c NOT LIKE '%glidepath.phases[0].is_minor = false%' THEN
    RAISE EXCEPTION 'FAIL [Werte nicht in die Prosa uebernommen: %]', c; END IF;
  IF position('Migriert' IN c) > position('## Gelernt' IN c) OR c NOT LIKE '%- Notiz' THEN
    RAISE EXCEPTION 'FAIL [Notiz nicht vor dem Gelernt-Block / Block verletzt: %]', c; END IF;
  IF (length(c) - length(replace(c, 'Migriert', ''))) / length('Migriert') <> 1 THEN
    RAISE EXCEPTION 'FAIL [zweiter Lauf hat die Notiz verdoppelt: %]', c; END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name = '__t_v032_clean__') <> 'sauber' THEN
    RAISE EXCEPTION 'FAIL [sauberer Kontext angefasst]'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'agent' AND table_name = 'guide_onboarding_state' AND column_name = 'skipped_at') THEN
    RAISE EXCEPTION 'FAIL [guide_onboarding_state.skipped_at nicht gedroppt]'; END IF;
  RAISE NOTICE 'PASS core:V032 [gesperrte Keys rekursiv entfernt + in Prosa vor Gelernt, Roh-Keys/_meta bleiben, idempotent, skipped_at weg]';
END $$;

ROLLBACK;
