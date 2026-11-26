-- tests/db/core/test_handoff_tasks_v039_migration.sql
-- core:V039 (echte Datei, zweimal) auf einer DB mit Alt-Zeilen: der Status-CHECK ohne 'deferred' (Fassung vor dem
--   Zustand "zurueckgestellt") wird ersetzt; Alt-Zeilen in allen vier alten Zustaenden bleiben unveraendert, danach ist
--   'deferred' erlaubt und ein unbekannter Status weiter abgelehnt; zweiter Lauf = no-op.
BEGIN;

DO $$
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','t',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111,'language','de')))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  DELETE FROM agent.handoff_tasks;
  -- Bestands-Fassung des Status-CHECKs
  ALTER TABLE agent.handoff_tasks DROP CONSTRAINT handoff_tasks_status_check;
  ALTER TABLE agent.handoff_tasks ADD CONSTRAINT handoff_tasks_status_check
      CHECK (status IN ('open', 'working', 'done', 'cancelled'));
  INSERT INTO agent.handoff_tasks (id, domain, package, person_id, section_key, kind, text, status, claimed_at, closed_at) VALUES
    (9001, 'finance', 'finance', 'erika', 'goals_triggers', 'savings_goal', 'Alt offen', 'open', NULL, NULL),
    (9002, 'finance', 'finance', 'erika', 'goals_triggers', 'savings_plan', 'Alt beansprucht', 'working', now(), NULL),
    (9003, 'finance', 'finance', 'erika', 'goals_triggers', 'other', 'Alt erledigt', 'done', now(), now()),
    (9004, 'finance', 'finance', 'erika', 'goals_triggers', 'other', 'Alt gestrichen', 'cancelled', NULL, now());
END $$;

\ir ../../../packages/core/db/migrations/V039__handoff_tasks_deferred_status.sql
\ir ../../../packages/core/db/migrations/V039__handoff_tasks_deferred_status.sql

DO $$
DECLARE
  v_ok boolean := false;
BEGIN
  IF (SELECT count(*) FROM pg_constraint WHERE conrelid = 'agent.handoff_tasks'::regclass AND conname = 'handoff_tasks_status_check'
       AND pg_get_constraintdef(oid) LIKE '%deferred%') <> 1 THEN
    RAISE EXCEPTION 'FAIL [Status-CHECK nicht getauscht: %]', (SELECT pg_get_constraintdef(oid) FROM pg_constraint
      WHERE conrelid = 'agent.handoff_tasks'::regclass AND conname = 'handoff_tasks_status_check'); END IF;
  IF (SELECT string_agg(id || '=' || status, ',' ORDER BY id) FROM agent.handoff_tasks)
     <> '9001=open,9002=working,9003=done,9004=cancelled' THEN
    RAISE EXCEPTION 'FAIL [Alt-Zeilen veraendert: %]', (SELECT jsonb_agg(to_jsonb(t)) FROM agent.handoff_tasks t); END IF;
  UPDATE agent.handoff_tasks SET status = 'deferred', blocked_code = 'end_date_future' WHERE id = 9001;
  IF (SELECT status FROM agent.handoff_tasks WHERE id = 9001) <> 'deferred' THEN RAISE EXCEPTION 'FAIL [deferred nicht moeglich]'; END IF;
  BEGIN
    INSERT INTO agent.handoff_tasks (domain, package, person_id, section_key, kind, text, status)
    VALUES ('finance', 'finance', 'erika', 'x', 'other', 't', 'paused');
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [unbekannter Status angenommen]'; END IF;
  RAISE NOTICE 'PASS core:V039 [Status-CHECK mit deferred, Alt-Zeilen unveraendert, unbekannter Status abgelehnt, idempotent]';
END $$;

ROLLBACK;
