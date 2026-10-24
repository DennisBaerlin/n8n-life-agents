-- tests/db/finance/test_fn_import_depot_conflict.sql
-- fn_import_depot_conflict: gedruckte Depotnummer/Inhaber gegen das gewaehlte Depot (Owner-Befund 2026-10-23).
--   Widerspruch: Nummer gehoert einem anderen Konto, Depot hat andere gespeicherte Nummer, Depot gehoert einer
--   anderen Person. Kein Widerspruch: Haushalts-Depot, nicht aufloesbarer Inhaber, Depot ohne Nummer, Batch-Depot.
BEGIN;

DO $$
DECLARE v_cash INT; v_t TEXT; v_res JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__dc_own','first_name','Dcown','last_name','Testfall',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-23'),
              jsonb_build_object('person_id','__dc_kid','first_name','Dckid','last_name','Testfall',
                                 'role','child','birth_date','2010-01-01','as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  v_cash := (finance.fn_create_account('{"name":"__t_dc_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_dc_own__','account_type','stocks_depot',
    'settlement_id', v_cash, 'owner_person_id', '__dc_own', 'account_number', '0148080277'));
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_dc_kid__','account_type','stocks_depot',
    'settlement_id', v_cash, 'owner_person_id', '__dc_kid'));
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_dc_hh__','account_type','stocks_depot',
    'settlement_id', v_cash));

  v_t := finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_own__","depot_number":"3916458877"}');
  IF v_t IS NULL OR v_t NOT LIKE '%has account number 0148080277%' THEN RAISE EXCEPTION 'FAIL gespeicherte Nummer: %', v_t; END IF;
  v_t := finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_kid__","depot_number":"0148 080277"}');
  IF v_t IS NULL OR v_t NOT LIKE '%belongs to "__t_dc_own__"%' THEN RAISE EXCEPTION 'FAIL fremde Nummer: %', v_t; END IF;
  v_t := finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_own__","depot_holder":"Dckid Testfall"}');
  IF v_t IS NULL OR v_t NOT LIKE '%another household member%' OR v_t NOT LIKE '%Dckid Testfall%' THEN
    RAISE EXCEPTION 'FAIL fremde Person: %', v_t; END IF;
  RAISE NOTICE 'PASS fn_import_depot_conflict [Nummer fremd / Nummer abweichend / Person fremd]';

  IF finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_hh__","depot_holder":"Dckid Testfall"}') IS NOT NULL
     OR finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_own__","depot_holder":"irgendwer"}') IS NOT NULL
     OR finance.fn_import_depot_conflict(NULL, '{"depot":"__t_dc_kid__","depot_number":"3916458877","depot_holder":"Dckid"}') IS NOT NULL
     OR finance.fn_import_depot_conflict(NULL, '{"depot_number":"0148080277"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL kein Widerspruch erwartet'; END IF;
  RAISE NOTICE 'PASS fn_import_depot_conflict [Haushalt / unklarer Inhaber / Depot ohne Nummer / ohne Depot]';

  -- Batch-Depot-Zeile mit Nummer: dieselbe Nummer an einer Position passt, eine andere widerspricht
  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__t_dc_new__','account_type','stocks_depot',
                       'settlement_account','__t_dc_cash__','account_number','7000111122'))));
  IF finance.fn_import_depot_conflict((v_res->>'batch_id')::uuid, '{"depot":"__t_dc_new__","depot_number":"7000111122"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL Batch-Depot mit gleicher Nummer'; END IF;
  v_t := finance.fn_import_depot_conflict((v_res->>'batch_id')::uuid, '{"depot":"__t_dc_new__","depot_number":"7000111199"}');
  IF v_t IS NULL OR v_t NOT LIKE '%has account number 7000111122%' THEN RAISE EXCEPTION 'FAIL Batch-Depot andere Nummer: %', v_t; END IF;
  RAISE NOTICE 'PASS fn_import_depot_conflict [Batch-Depot-Zeile]';
END $$;

ROLLBACK;
