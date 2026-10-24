-- tests/db/finance/test_fn_import_balance_targets.sql
-- fn_import_balance_targets: Cash-Stand einer Depot-Uebersicht -> Verrechnungskonto des Depots (Owner-Fall 2026-10-23)
--   (1) Depot per Nummer -> Verrechnungskonto, Saldo zum Druckdatum, Differenz, deutsche Zahl
--   (2) Fehler: Datum fehlt, Datum in der Zukunft, unbekanntes Depot, zweite Zeile fuer dasselbe Konto,
--       Depot erst im Batch (opening_balance-Hinweis), Nummern-Widerspruch
--   (3) fn_reconcile_open_due zaehlt die Vorkommen, die der Abgleich als erledigt markiert (gleiche Menge wie der Write)
BEGIN;

DO $$
DECLARE v_cash INT; v_cash2 INT; v_depot INT; v JSONB; v_res JSONB; v_rp INT;
BEGIN
  v_cash  := (finance.fn_create_account('{"name":"__t_bt_cash__","account_type":"cash","currency":"EUR","opening_balance":3104.97}'::jsonb)->>'account_id')::int;
  v_cash2 := (finance.fn_create_account('{"name":"__t_bt_cash2__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__t_bt_depot__','account_type','stocks_depot',
               'settlement_id', v_cash, 'account_number', '3916458877'))->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_bt_depot2__','account_type','stocks_depot',
               'settlement_id', v_cash2, 'account_number', '1111222233'));

  -- (1)
  v := finance.fn_import_balance_targets(NULL, jsonb_build_array(
         jsonb_build_object('depot_number','3916 458877','balance','3.054,97','balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD'))));
  IF (v->0->>'ok')::boolean IS DISTINCT FROM true OR v->0->>'account_name' IS DISTINCT FROM '__t_bt_cash__'
     OR (v->0->>'balance_before')::numeric <> 3104.97 OR (v->0->>'balance')::numeric <> 3054.97
     OR (v->0->>'difference')::numeric <> -50.00 THEN
    RAISE EXCEPTION 'FAIL (1) Zuordnung: %', v; END IF;
  RAISE NOTICE 'PASS (1) Depotnummer -> Verrechnungskonto, Differenz -50,00';

  -- (2)
  v := finance.fn_import_balance_targets(NULL, jsonb_build_array(
         jsonb_build_object('depot_number','3916458877','balance',1),
         jsonb_build_object('depot','__t_bt_depot2__','balance',1,'balance_date', to_char(CURRENT_DATE + 3,'YYYY-MM-DD')),
         jsonb_build_object('depot','__t_bt_gibtsnicht__','balance',1,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD')),
         jsonb_build_object('depot','__t_bt_depot2__','depot_number','3916458877','balance',1,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD')),
         jsonb_build_object('depot','__t_bt_depot__','balance',2,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD')),
         jsonb_build_object('depot','__t_bt_depot__','balance',3,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD'))));
  -- Zeile 4: die gedruckte Nummer gehoert Depot 1 -> sie gewinnt gegen den geratenen Namen (Identitaet), Zeilen 5/6
  -- treffen dann dasselbe Verrechnungskonto -> doppelt
  IF v->0->>'error' NOT LIKE 'balance_date%'
     OR v->1->>'error' NOT LIKE '%in the future%'
     OR v->2->>'error' NOT LIKE '%not found%'
     OR (v->3->>'ok')::boolean IS DISTINCT FROM true OR v->3->>'account_name' IS DISTINCT FROM '__t_bt_cash__'
     OR v->4->>'error' NOT LIKE 'more than one balance%'
     OR v->5->>'error' NOT LIKE 'more than one balance%' THEN
    RAISE EXCEPTION 'FAIL (2) Fehlerfaelle: %', v; END IF;
  v := finance.fn_import_balance_targets(NULL, jsonb_build_array(
         jsonb_build_object('depot','__t_bt_depot2__','depot_number','5555666677','balance',1,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD'))));
  IF v->0->>'error' NOT LIKE '%has account number 1111222233%' THEN RAISE EXCEPTION 'FAIL (2) Nummern-Widerspruch: %', v; END IF;
  v_res := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__t_bt_new_depot__','account_type','stocks_depot',
                       'settlement_account','__t_bt_cash2__'))));
  v := finance.fn_import_balance_targets((v_res->>'batch_id')::uuid, jsonb_build_array(
         jsonb_build_object('depot','__t_bt_new_depot__','balance',5,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD'))));
  IF v->0->>'error' NOT LIKE '%new in this import%opening_balance%' THEN RAISE EXCEPTION 'FAIL (2) Batch-Depot: %', v; END IF;
  RAISE NOTICE 'PASS (2) Datum fehlt/Zukunft, unbekannt, Nummern-Widerspruch, doppelt, Batch-Depot';

  -- (3) offener Dauerauftrag auf dem Verrechnungskonto, faellig vor 30 Tagen -> skip_count 1; der Abgleich markiert genau ihn
  v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name','__t_bt_sparplan_cash__','direction','expense',
            'amount', 50, 'account_id', v_cash, 'schedule_unit','month', 'first_payment_date', to_char(CURRENT_DATE - 30,'YYYY-MM-DD')))
            ->>'recurring_payment_id')::int;
  IF v_rp IS NULL THEN RAISE EXCEPTION 'FAIL (3) setup recurring'; END IF;
  -- fn_recurring_valid_from klemmt den Beginn auf die Konto-Eroeffnung (heute) -> fuer den Test zurueckdatieren
  UPDATE finance.recurring_payments SET valid_from = CURRENT_DATE - 30 WHERE id = v_rp;
  v := finance.fn_import_balance_targets(NULL, jsonb_build_array(
         jsonb_build_object('depot','__t_bt_depot__','balance',3054.97,'balance_date', to_char(CURRENT_DATE,'YYYY-MM-DD'))));
  IF (v->0->>'skip_count')::int < 1 THEN RAISE EXCEPTION 'FAIL (3) skip_count: %', v; END IF;
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_cash, 'confirmed_balance', 3054.97,
             'reconciliation_date', to_char(CURRENT_DATE,'YYYY-MM-DD')));
  IF (v_res->>'skipped_occurrences')::int IS DISTINCT FROM (v->0->>'skip_count')::int THEN
    RAISE EXCEPTION 'FAIL (3) Vorschau % <> Write %', v->0->>'skip_count', v_res; END IF;
  RAISE NOTICE 'PASS (3) skip_count = als erledigt markierte Vorkommen des Abgleichs';
END $$;

ROLLBACK;
