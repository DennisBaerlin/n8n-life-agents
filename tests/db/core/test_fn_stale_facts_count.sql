-- tests/db/core/test_fn_stale_facts_count.sql
-- Phase A: core.fn_stale_facts_count() — der Aktualitaets-Waechter household_facts_freshness zaehlt veraltete
-- (as_of > 12 Monate oder fehlend) persons[]-Eintraege ueber family + household-Fakten-Kontexte AKTIVER Pakete
-- (core.fn_facts_context_allowed). Kein Paket-Literal; Fakten inaktiver Pakete / unregistrierter Kontexte zaehlen
-- nicht. Laeuft unter core_ro (fn_monitor_acquire SET LOCAL ROLE core_ro) -> Perspektiv-Test.
BEGIN;

DO $$
DECLARE
  v_old TEXT := to_char(CURRENT_DATE - INTERVAL '2 years', 'YYYY-MM-DD');
  v_now TEXT := to_char(CURRENT_DATE, 'YYYY-MM-DD');
  v_n   INT;
BEGIN
  UPDATE agent.core_contexts SET metadata = jsonb_set(metadata, '{facts,persons}', '[]'::jsonb)
  WHERE name <> 'family' AND jsonb_typeof(metadata->'facts'->'persons') = 'array';
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('family', 'fixture', 'lazy', 'x', 'agent', 'core', jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(
      jsonb_build_object('person_id','erika','first_name','Erika','last_name','M','role','owner','birth_date','1980-05-20','as_of', v_now),
      jsonb_build_object('person_id','lisa','first_name','Lisa','last_name','M','role','child','birth_date','2023-02-17','as_of', v_old)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;

  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.context_validators (context_name, validate_fn, package)
  VALUES ('finance_profile', 'finance.fn_validate_finance_profile', 'finance')
  ON CONFLICT (context_name) DO UPDATE SET package = EXCLUDED.package;
  -- finance_profile: erika ohne as_of (zaehlt als veraltet)
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, managed_by, package, metadata)
  VALUES ('finance_profile', 'fixture', 'finance_advisor', 'lazy', 'x', 'agent', 'finance',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','erika','steuerklasse',3)))))
  ON CONFLICT (name) DO UPDATE SET metadata = EXCLUDED.metadata;
  -- unregistrierter persons-Kontext mit veraltetem Eintrag -> zaehlt NICHT
  INSERT INTO agent.core_contexts (name, description, load_strategy, content, managed_by, package, metadata)
  VALUES ('__test_unreg_persons__', 'x', 'lazy', 'x', 'agent', 'core',
          jsonb_build_object('facts', jsonb_build_object('persons', jsonb_build_array(jsonb_build_object('person_id','lisa','as_of', v_old)))));

  v_n := core.fn_stale_facts_count();
  IF v_n IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL [aktiv]: erwartet 2 (family:lisa alt + finance_profile:erika ohne as_of), got %', v_n;
  END IF;
  RAISE NOTICE 'PASS stale_facts_count [family + aktiver Paket-Kontext; unregistrierter Kontext zaehlt nicht]';

  UPDATE core.package_registry SET status = 'inactive' WHERE package = 'finance';
  v_n := core.fn_stale_facts_count();
  IF v_n IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL [inaktiv]: erwartet 1 (nur family:lisa), got %', v_n;
  END IF;
  UPDATE core.package_registry SET status = 'active' WHERE package = 'finance';
  RAISE NOTICE 'PASS stale_facts_count [inaktives Paket weckt den Owner nicht]';

  -- core_ro-Perspektive (so ruft fn_monitor_acquire die gespeicherte Spec auf)
  SET LOCAL ROLE core_ro;
  v_n := core.fn_stale_facts_count();
  RESET ROLE;
  IF v_n IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL [core_ro]: erwartet 2 unter core_ro, got %', v_n;
  END IF;
  RAISE NOTICE 'PASS stale_facts_count [unter core_ro ausfuehrbar]';

  -- die Core-Trigger-Zeile ruft genau die fn (Init-Seed)
  IF (SELECT acquisition_spec->>'query' FROM agent.monitor_triggers
      WHERE origin = 'core' AND label = 'household_facts_freshness') IS DISTINCT FROM 'SELECT core.fn_stale_facts_count()' THEN
    RAISE EXCEPTION 'FAIL [seed]: household_facts_freshness ruft nicht core.fn_stale_facts_count()';
  END IF;
  RAISE NOTICE 'PASS stale_facts_count [Core-Trigger-Spec ruft die fn]';
END $$;

ROLLBACK;
