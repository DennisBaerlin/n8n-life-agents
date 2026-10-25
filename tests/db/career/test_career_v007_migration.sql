-- tests/db/career/test_career_v007_migration.sql
-- career:V007 (ECHTE Datei, zweimal): Jahresspannen im Bestand -> Roh-Daten gegen den Anker (_meta.last_confirmed_at
--   bzw. saved_at): experience_years 7.5 -> career_start_date Ankerjahr-7, skills years_experience -> since,
--   timeline_years 1.5 -> target_date Ankerjahr+2, Nicht-Zahl "5+" -> Key weg + Zeile in der Prosa, vorhandenes
--   Roh-Feld gewinnt, Draft-Sektion umgerechnet, _meta unveraendert, zweiter Lauf = no-op.
--   Der Fixture-Insert umgeht den Fakten-Trigger (die neuen Validatoren lehnen die Alt-Keys heute ab = Altbestand).
BEGIN;

ALTER TABLE agent.core_contexts DISABLE TRIGGER trg_validate_household_facts;
INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
VALUES ('career_profile__t_v007a', 't', NULL, 'lazy', 'Profil', 'agent', 'career',
        jsonb_build_object('facts', jsonb_build_object('experience_years', 7.5,
          'skills', jsonb_build_array(jsonb_build_object('name', 'SQL', 'years_experience', 3),
                                      jsonb_build_object('name', 'Go', 'years_experience', '5+')),
          '_meta', jsonb_build_object('last_confirmed_at', '2024-03-10')))),
       ('career_profile__t_v007b', 't', NULL, 'lazy', 'Profil B', 'agent', 'career',
        jsonb_build_object('facts', jsonb_build_object('experience_years', 'viele', 'career_start_date', '2010'))),
       ('career_planning__t_v007a', 't', NULL, 'lazy', 'Plan', 'agent', 'career',
        jsonb_build_object('facts', jsonb_build_object('timeline_years', 1.5,
          '_meta', jsonb_build_object('last_confirmed_at', '2025-06-01'))));
ALTER TABLE agent.core_contexts ENABLE TRIGGER trg_validate_household_facts;
INSERT INTO agent.advisor_plans (domain, person_id, plan_name, status, version, interview_state)
VALUES ('career', NULL, '__t_v007__', 'draft', 1,
        jsonb_build_object('targets', jsonb_build_object('content', 'Ziele', 'saved_at', '2025-02-01T10:00:00+00:00',
          'data', jsonb_build_object('timeline_years', 3, 'target_roles', jsonb_build_array()))));

\ir ../../../packages/career/db/migrations/V007__career_facts_raw_dates.sql
\ir ../../../packages/career/db/migrations/V007__career_facts_raw_dates.sql

DO $$
DECLARE
  f jsonb;
BEGIN
  SELECT metadata->'facts' INTO f FROM agent.core_contexts WHERE name = 'career_profile__t_v007a';
  IF f ? 'experience_years' OR f->>'career_start_date' IS DISTINCT FROM '2017'
     OR f#>>'{skills,0,since}' IS DISTINCT FROM '2021' OR f->'skills'->0 ? 'years_experience'
     OR f->'skills'->1 ? 'years_experience' OR f->'skills'->1 ? 'since'
     OR f->'_meta'->>'last_confirmed_at' IS DISTINCT FROM '2024-03-10' THEN
    RAISE EXCEPTION 'FAIL [Profil a: %]', f; END IF;
  IF (SELECT content FROM agent.core_contexts WHERE name = 'career_profile__t_v007a') NOT LIKE '%Erfahrung Go = 5+%' THEN
    RAISE EXCEPTION 'FAIL [Nicht-Zahl nicht in die Prosa]'; END IF;
  IF (SELECT length(content) - length(replace(content, 'Migriert', '')) FROM agent.core_contexts
       WHERE name = 'career_profile__t_v007a') <> length('Migriert') THEN
    RAISE EXCEPTION 'FAIL [zweiter Lauf verdoppelt die Notiz]'; END IF;
  SELECT metadata->'facts' INTO f FROM agent.core_contexts WHERE name = 'career_profile__t_v007b';
  IF f ? 'experience_years' OR f->>'career_start_date' IS DISTINCT FROM '2010' THEN
    RAISE EXCEPTION 'FAIL [Profil b: vorhandenes Roh-Feld muss gewinnen: %]', f; END IF;
  SELECT metadata->'facts' INTO f FROM agent.core_contexts WHERE name = 'career_planning__t_v007a';
  IF f ? 'timeline_years' OR f->>'target_date' IS DISTINCT FROM '2027' THEN
    RAISE EXCEPTION 'FAIL [Plan: %]', f; END IF;
  SELECT interview_state->'targets'->'data' INTO f FROM agent.advisor_plans WHERE plan_name = '__t_v007__';
  IF f ? 'timeline_years' OR f->>'target_date' IS DISTINCT FROM '2028' THEN
    RAISE EXCEPTION 'FAIL [Draft: %]', f; END IF;
  IF career.fn_validate_career_profile((SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'career_profile__t_v007a')) IS NOT NULL
     OR career.fn_validate_career_planning((SELECT metadata->'facts' FROM agent.core_contexts WHERE name = 'career_planning__t_v007a')) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [Ergebnis besteht die neuen Validatoren nicht]'; END IF;
  IF EXISTS (SELECT 1 FROM information_schema.columns
              WHERE table_schema = 'career' AND table_name = 'onboarding_state' AND column_name = 'skipped_at') THEN
    RAISE EXCEPTION 'FAIL [career.onboarding_state.skipped_at nicht gedroppt]'; END IF;
  RAISE NOTICE 'PASS career:V007 [Spannen -> Roh-Daten gegen den Anker, Nicht-Zahl in Prosa, Roh-Feld gewinnt, Draft, idempotent, Validatoren gruen]';
END $$;

ROLLBACK;
