-- tests/db/estate/test_v002_case_flags_register_derived.sql
-- estate:V002 (ECHTE Datei, zweimal): Bestand an die WP3-Regeln angleichen —
--   (1) Alt-Default-false aus cases.flags entfernt, true bleibt; (2) status_source der Bestands-Tasks rekonstruiert
--   (done/Knopf-n.a./n.a. trotz wahrem Merkmal -> user, sonst system); (3) done_at <-> done angeglichen + CHECK;
--   (4) Anbieter => Vorsorgevertrag + CHECK. Die Fixture entfernt die CHECKs vorher (Altbestand vor WP3).
BEGIN;

ALTER TABLE estate.case_tasks DROP CONSTRAINT case_tasks_done_at_consistency;
ALTER TABLE estate.funeral_preferences DROP CONSTRAINT funeral_preferences_provider_implies_contract;

INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
VALUES ('family','fx',NULL,'lazy',E'## P', jsonb_build_object('facts', jsonb_build_object('persons',
  jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','hans','first_name','Hans','last_name','M','role','partner','birth_date','1979-02-02')))))
ON CONFLICT (name) DO UPDATE SET metadata = excluded.metadata;

INSERT INTO estate.cases (case_type, subject_person_id, event_date, knowledge_date, bundesland, flags)
VALUES ('death', 'hans', '2026-10-01', '2026-10-01', 'bayern',
        '{"tenant": false, "employed": true, "has_will": false, "no_poa": false}'::jsonb);
INSERT INTO estate.case_tasks (case_id, template_key, subject_ref, phase, title, status, done_at)
SELECT c.id, v.k, '', 'first_week', v.k AS title, v.st, NULL
  FROM estate.cases c,
       (VALUES ('death_certificate', 'done'),            -- done ohne done_at
               ('manage_contracts', 'not_applicable'),   -- bedingungslos n.a. -> Knopf -> user
               ('notify_employer', 'not_applicable'),    -- employed=true, trotzdem n.a. -> user
               ('tenancy', 'not_applicable'),            -- tenant (Default) -> system
               ('order_death_certs', 'open')) AS v (k, st)
 WHERE c.subject_person_id = 'hans';
UPDATE estate.case_tasks SET done_at = now() WHERE template_key = 'order_death_certs';   -- offen MIT done_at
INSERT INTO estate.funeral_preferences (person_id, has_prepaid_contract, prepaid_contract_provider)
VALUES ('hans', FALSE, 'Bestattungshaus Muster'), ('erika', NULL, NULL);

\ir ../../../packages/estate/db/migrations/V002__case_flags_register_derived.sql
\ir ../../../packages/estate/db/migrations/V002__case_flags_register_derived.sql

DO $$
BEGIN
  IF (SELECT flags FROM estate.cases WHERE subject_person_id = 'hans') IS DISTINCT FROM '{"employed": true}'::jsonb THEN
    RAISE EXCEPTION 'FAIL (1) flags: %', (SELECT flags FROM estate.cases WHERE subject_person_id = 'hans'); END IF;
  IF (SELECT string_agg(template_key || '=' || status_source, ',' ORDER BY template_key) FROM estate.case_tasks)
     IS DISTINCT FROM 'death_certificate=user,manage_contracts=user,notify_employer=user,order_death_certs=system,tenancy=system' THEN
    RAISE EXCEPTION 'FAIL (2) status_source: %',
      (SELECT string_agg(template_key || '=' || status_source, ',' ORDER BY template_key) FROM estate.case_tasks); END IF;
  IF EXISTS (SELECT 1 FROM estate.case_tasks WHERE (status = 'done') <> (done_at IS NOT NULL)) THEN
    RAISE EXCEPTION 'FAIL (3) done_at nicht angeglichen'; END IF;
  IF (SELECT has_prepaid_contract FROM estate.funeral_preferences WHERE person_id = 'hans') IS DISTINCT FROM true
     OR (SELECT has_prepaid_contract FROM estate.funeral_preferences WHERE person_id = 'erika') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (4) Vorsorgevertrag aus Anbieter'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'case_tasks_done_at_consistency')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'funeral_preferences_provider_implies_contract') THEN
    RAISE EXCEPTION 'FAIL (3/4) CHECKs nicht (wieder) angelegt'; END IF;
  RAISE NOTICE 'PASS estate:V002 [Alt-false weg, status_source rekonstruiert, done_at/Vorsorge angeglichen + CHECKs, 2 Laeufe]';
END $$;

ROLLBACK;
