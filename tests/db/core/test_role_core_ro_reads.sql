-- tests/db/core/test_role_core_ro_reads.sql
-- Rollen-Perspektive core_ro (Credential der Orchestrator-/Cron-Knoten): die beiden reinen Lese-Helfer
--   agent.fn_owner_person_id() (Owner-Slug aus family.facts) und core.fn_smalltalk_kind(text) (Dank/Gruß/Ping-Erkennung)
--   werden direkt unter core_ro aufgerufen. Fixture und Assertions laufen als Superuser; fehlendes USAGE/EXECUTE
--   (Schema agent/core, Helfer-fns, core_contexts-Lesezugriff) bricht den Block ab.
BEGIN;

DO $$
DECLARE
  v_owner text;
  v_kind  text;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family','fx',NULL,'lazy','f', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
    jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','telegram_user_id',111),
    jsonb_build_object('person_id','max','first_name','Max','last_name','M','role','partner','birth_date','1979-02-02','telegram_user_id',222)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  -- agent.fn_owner_person_id: Slug der Person mit role=owner (nicht der Partner).
  SET LOCAL ROLE core_ro;
  v_owner := agent.fn_owner_person_id();
  RESET ROLE;
  IF v_owner IS DISTINCT FROM 'erika' THEN RAISE EXCEPTION 'FAIL [fn_owner_person_id core_ro]: %', quote_nullable(v_owner); END IF;
  RAISE NOTICE 'PASS fn_owner_person_id core_ro';

  -- core.fn_smalltalk_kind: reiner Dank -> thanks.
  SET LOCAL ROLE core_ro;
  v_kind := core.fn_smalltalk_kind('Danke dir!');
  RESET ROLE;
  IF v_kind IS DISTINCT FROM 'thanks' THEN RAISE EXCEPTION 'FAIL [fn_smalltalk_kind thanks core_ro]: %', quote_nullable(v_kind); END IF;

  -- reiner Gruß -> greeting.
  SET LOCAL ROLE core_ro;
  v_kind := core.fn_smalltalk_kind('Guten Morgen');
  RESET ROLE;
  IF v_kind IS DISTINCT FROM 'greeting' THEN RAISE EXCEPTION 'FAIL [fn_smalltalk_kind greeting core_ro]: %', quote_nullable(v_kind); END IF;

  -- Dank mit Inhalt ist kein Smalltalk -> NULL.
  SET LOCAL ROLE core_ro;
  v_kind := core.fn_smalltalk_kind('Danke, und buch noch 5 € Kaffee');
  RESET ROLE;
  IF v_kind IS NOT NULL THEN RAISE EXCEPTION 'FAIL [fn_smalltalk_kind Inhalt core_ro]: %', quote_nullable(v_kind); END IF;
  RAISE NOTICE 'PASS fn_smalltalk_kind core_ro';
END $$;

ROLLBACK;
