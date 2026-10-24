-- tests/db/finance/test_fn_import_resolve_depot.sql
-- Owner-Befund 2026-10-23 (Annas Vermoegensuebersicht): Positionen ohne Ticker/Einstand, Depot geraten (falsches Depot),
-- Depot ohne gespeicherte Nummer. Prueft:
--   (1) fn_import_resolve_depot: Nummer > Inhaber > NULL; nicht aufloesbarer Inhaber/Krypto ohne Depot -> NULL
--   (2) widerspruchsfreies extrahiertes Depot bleibt; Inhaber-Depot mit fremder Nummer wird nicht gewaehlt
--       (Widersprueche selbst: test_fn_import_depot_conflict.sql)
--   (3) Ende-zu-Ende: Stage korrigiert das geratene Depot per Inhaber, Fehler tragen row (Allow-List) und den
--       Einstands-Hinweis, nach dem Nachtrag zeigt die Karte Kennung + zu speichernde Nummer, der Probelauf
--       schreibt nichts, der Commit speichert die Nummer und bucht mit Kennung = ISIN; ein zweiter Import findet
--       das Depot per Nummer.
BEGIN;

DO $$
DECLARE
  v_cash INT; v_cash2 INT; v_own INT; v_anna INT; v_hh INT;
  v JSONB; v_t TEXT; v_res JSONB; v_batch UUID; v_card JSONB; v_err JSONB;
BEGIN
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__rd_own','first_name','Rdown','last_name','Testfall',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-23'),
              jsonb_build_object('person_id','__rd_kid','first_name','Rdkid','last_name','Testfall',
                                 'role','child','birth_date','2010-01-01','as_of','2026-10-23')))))
  ON CONFLICT (name) DO UPDATE
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  v_cash  := (finance.fn_create_account('{"name":"__t_rd_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_cash2 := (finance.fn_create_account('{"name":"__t_rd_cash_kid__","account_type":"cash","currency":"EUR","owner_person_id":"__rd_kid"}'::jsonb)->>'account_id')::int;
  v_own   := (finance.fn_create_account(jsonb_build_object('name','__t_rd_depot_own__','account_type','stocks_depot',
               'settlement_id', v_cash, 'owner_person_id', '__rd_own', 'account_number', '0148080299'))->>'account_id')::int;
  v_anna  := (finance.fn_create_account(jsonb_build_object('name','__t_rd_depot_kid__','account_type','stocks_depot',
               'settlement_id', v_cash2, 'owner_person_id', '__rd_kid'))->>'account_id')::int;
  v_hh    := (finance.fn_create_account(jsonb_build_object('name','__t_rd_depot_hh__','account_type','stocks_depot',
               'settlement_id', v_cash))->>'account_id')::int;
  IF v_own IS NULL OR v_anna IS NULL OR v_hh IS NULL THEN RAISE EXCEPTION 'FAIL setup'; END IF;

  -- (1) Aufloesung
  v := finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot_number":"0148 080299","depot_holder":"Rdkid Testfall"}');
  IF v->>'depot' IS DISTINCT FROM '__t_rd_depot_own__' OR v->>'source' IS DISTINCT FROM 'number' THEN
    RAISE EXCEPTION 'FAIL (1) Nummer vor Inhaber: %', v; END IF;
  v := finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot_number":"3916458899","depot_holder":"Rdkid Testfall"}');
  IF v->>'depot' IS DISTINCT FROM '__t_rd_depot_kid__' OR v->>'source' IS DISTINCT FROM 'holder' THEN
    RAISE EXCEPTION 'FAIL (1) Inhaber: %', v; END IF;
  IF finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot_holder":"Rdown und Rdkid Testfall"}') IS NOT NULL
     OR finance.fn_import_resolve_depot(NULL, '{"symbol":"BTC","depot_holder":"Rdkid Testfall"}') IS NOT NULL
     OR finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (1) kein Treffer muss NULL sein'; END IF;
  RAISE NOTICE 'PASS (1) fn_import_resolve_depot [Nummer > Inhaber > NULL]';

  -- (2) Review 2026-10-23: ein widerspruchsfreies extrahiertes Depot bleibt (Haushalts-Depot gegen Inhaberin);
  --     ein Inhaber-Depot mit ANDERER gespeicherter Nummer wird nicht gewaehlt (waere sofort ein Widerspruch)
  IF finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot":"__t_rd_depot_hh__","depot_holder":"Rdkid Testfall"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (2) Haushalts-Depot muss bleiben'; END IF;
  IF finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot_number":"5555000011","depot_holder":"Rdown Testfall"}') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (2) Inhaber-Depot mit fremder Nummer darf nicht gewaehlt werden'; END IF;
  v := finance.fn_import_resolve_depot(NULL, '{"isin":"IE00BYML9W36","depot":"__t_rd_depot_own__","depot_number":"3916458899","depot_holder":"Rdkid Testfall"}');
  IF v->>'depot' IS DISTINCT FROM '__t_rd_depot_kid__' THEN
    RAISE EXCEPTION 'FAIL (2) widersprechendes extrahiertes Depot muss ersetzt werden: %', v; END IF;
  RAISE NOTICE 'PASS (2) widerspruchsfreies Depot bleibt, Inhaber-Depot nur ohne fremde Nummer';

  -- (3) Ende-zu-Ende: das Modell raet das Owner-Depot, gedruckt sind Nummer (unbekannt) + Inhaberin
  v_res := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
    jsonb_build_object('entity_type','stock_buy','depot','__t_rd_depot_own__','depot_number','3916458899',
                       'depot_holder','Rdkid Testfall','isin','US84615Q1031','name','Space Exploration Techs. Corp.',
                       'shares','1,343429'),
    jsonb_build_object('entity_type','stock_buy','depot','__t_rd_depot_own__','depot_number','3916458899',
                       'depot_holder','Rdkid Testfall','isin','IE00BYML9W36','name','S&P 500 (Dist)',
                       'shares','42,731759'))));
  v_batch := (v_res->>'batch_id')::uuid;
  IF (v_res->>'invalid')::int <> 2 THEN RAISE EXCEPTION 'FAIL (3) stage: %', v_res; END IF;
  v_err := v_res->'errors'->0;
  IF v_err->>'error' NOT LIKE 'purchase price missing%' OR v_err->>'entity_type' IS DISTINCT FROM 'stock_buy'
     OR v_err->'row'->>'depot' IS DISTINCT FROM '__t_rd_depot_kid__'
     OR v_err->'row'->>'isin' IS DISTINCT FROM 'US84615Q1031' OR (v_err->'row'->>'shares')::numeric IS DISTINCT FROM 1.343429
     OR v_err->'row'->>'name' IS NULL THEN
    RAISE EXCEPTION 'FAIL (3) Fehler mit row: %', v_err; END IF;
  RAISE NOTICE 'PASS (3a) Depot per Inhaberin korrigiert, Fehler tragen row + Einstands-Hinweis';

  -- Einstand nachtragen (gesamt bzw. je Stueck, roh) -> gueltig; Korrektur des Depots bleibt (kein Re-Resolve)
  v := finance.fn_import_update_row(jsonb_build_object('batch_id', v_batch, 'row_no', 1,
         'payload_merge', jsonb_build_object('cost_basis_total', '150,00')));
  v := finance.fn_import_update_row(jsonb_build_object('batch_id', v_batch, 'row_no', 2,
         'payload_merge', jsonb_build_object('price_per_share', '55.10')));
  IF (v->>'invalid')::int <> 0 OR (v->>'valid')::int <> 2 THEN RAISE EXCEPTION 'FAIL (3) nach Nachtrag: %', v; END IF;

  v_card := finance.fn_import_card_rows(v_batch);
  IF v_card->0->'x'->>'symbol' IS DISTINCT FROM 'US84615Q1031'
     OR v_card->0->'x'->>'depot_number_to_store' IS DISTINCT FROM '3916458899'
     OR v_card->0->'p' ? 'symbol' THEN
    RAISE EXCEPTION 'FAIL (3) Karte: %', v_card->0; END IF;
  RAISE NOTICE 'PASS (3b) Karte: Kennung = ISIN, Depotnummer wird gespeichert, p bleibt roh';

  v := finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch, 'dry_run', true));
  IF (v->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT account_number FROM finance.accounts WHERE id = v_anna) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (3) Probelauf: %', v; END IF;
  v := finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch));
  IF (v->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (3) Commit: %', v; END IF;
  IF (SELECT account_number FROM finance.accounts WHERE id = v_anna) IS DISTINCT FROM '3916458899'
     OR (SELECT count(*) FROM finance.depot_holdings WHERE account_id = v_anna AND symbol = isin) <> 2
     OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE account_id = v_own) THEN
    RAISE EXCEPTION 'FAIL (3) Post-State Commit'; END IF;
  RAISE NOTICE 'PASS (3c) Probelauf schreibt nichts; Commit speichert Nummer, bucht ins richtige Depot';

  -- erneuter Import desselben Dokuments: Depot per Nummer, Positionen schon gehalten -> Zeilenfehler statt Dublette
  v_res := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
    jsonb_build_object('entity_type','stock_buy','depot','__t_rd_depot_own__','depot_number','3916458899',
                       'isin','IE00BYML9W36','shares','42,731759','price_per_share','55.10'))));
  IF (v_res->'errors'->0->'row'->>'depot') IS DISTINCT FROM '__t_rd_depot_kid__'
     OR (v_res->'errors'->0->>'error') NOT LIKE '%already holds%' THEN
    RAISE EXCEPTION 'FAIL (3d) Re-Import: %', v_res; END IF;
  RAISE NOTICE 'PASS (3d) Re-Import findet das Depot per Nummer, keine Doppel-Position';
END $$;

ROLLBACK;
