-- tests/db/finance/test_fn_import_depot_number_to_store.sql
-- fn_import_depot_number_to_store: gedruckte Depotnummer nur fuer ein BESTANDS-Depot ohne Nummer (Owner 2026-10-23);
-- Depot mit Nummer, Batch-Depot-Zeile, Nicht-Depot oder fehlende Nummer -> NULL.
BEGIN;

DO $$
DECLARE v_cash INT; v_res JSONB;
BEGIN
  v_cash := (finance.fn_create_account('{"name":"__t_ns_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_ns_ohne__','account_type','stocks_depot','settlement_id', v_cash));
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_ns_mit__','account_type','stocks_depot','settlement_id', v_cash,
    'account_number','1234500099'));

  IF finance.fn_import_depot_number_to_store(NULL, '{"depot":"__t_ns_ohne__","depot_number":"3916 4588 01"}') IS DISTINCT FROM '3916458801' THEN
    RAISE EXCEPTION 'FAIL Depot ohne Nummer: normalisierte Nummer erwartet'; END IF;
  IF finance.fn_import_depot_number_to_store(NULL, '{"depot":"__t_ns_mit__","depot_number":"3916458801"}') IS NOT NULL
     OR finance.fn_import_depot_number_to_store(NULL, '{"depot":"__t_ns_cash__","depot_number":"3916458801"}') IS NOT NULL
     OR finance.fn_import_depot_number_to_store(NULL, '{"depot":"__t_ns_ohne__"}') IS NOT NULL
     OR finance.fn_import_depot_number_to_store(NULL, '{"depot_number":"3916458801"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL NULL erwartet (Depot mit Nummer / Nicht-Depot / ohne Nummer / ohne Depot)'; END IF;

  -- gleichnamige Depot-Zeile im Batch: das neue Depot traegt seine Nummer selbst -> nichts nachtragen
  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__t_ns_ohne__','account_type','stocks_depot',
                       'settlement_account','__t_ns_cash__'))));
  IF finance.fn_import_depot_number_to_store((v_res->>'batch_id')::uuid, '{"depot":"__t_ns_ohne__","depot_number":"3916458801"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL Batch-Depot-Zeile: NULL erwartet'; END IF;
  RAISE NOTICE 'PASS fn_import_depot_number_to_store';
END $$;

ROLLBACK;
