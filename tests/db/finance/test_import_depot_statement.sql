-- tests/db/finance/test_import_depot_statement.sql
-- Monats-Check WP-G: Depotauszug-Import robuster (Owner-Befund 2026-10-22: Trade-Republic-Auszug lieferte keinen
-- Stueckpreis, obwohl Einstand gedruckt war).
--   (1) cost_basis_total (gedruckter Gesamt-Einstand) -> die DB leitet price_per_share = Einstand / Stueck ab
--   (2) average_purchase_price (gedruckter Durchschnittskurs) ist ein Alias fuer price_per_share, kein Sperr-Key
--   (3) provider_symbol ist erlaubt und landet an der Position; fn_import_bundle liefert positions[] (Post-State)
--   (4) depot_holdings_overview fuehrt holding_id (die Tool-Descriptions verweisen darauf)
BEGIN;

DO $$
DECLARE v_res JSONB; v_batch UUID; v_p JSONB; v_settle INT; v_pos JSONB;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__t_ids_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__t_ids_depot__','account_type','stocks_depot',
    'currency','EUR','settlement_id', v_settle));

  -- (1) + (2)
  v_res := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
    jsonb_build_object('entity_type','stock_buy','depot','__t_ids_depot__','isin','IE00B3YCGJ38','symbol','P500',
                       'name','S&P 500 USD (Acc)','shares','1.784,63817','cost_basis_total','23.753,53'),
    jsonb_build_object('entity_type','stock_buy','depot','__t_ids_depot__','isin','IE00BK5BQT80','symbol','VWCE',
                       'name','All-World','shares','10','average_purchase_price','98,50','provider_symbol','vwce.de'))));
  IF (v_res->>'invalid')::int <> 0 OR (v_res->>'valid')::int <> 2 THEN RAISE EXCEPTION 'FAIL (1/2) stage: %', v_res; END IF;
  v_batch := (v_res->>'batch_id')::uuid;
  SELECT payload INTO v_p FROM finance.import_staging WHERE batch_id = v_batch AND row_no = 1;
  -- 8 Nachkommastellen = Spaltenpraezision von unit_price/average_purchase_price (Rundungs-Paket 2026-10-23; vorher 6)
  IF (v_p->>'price_per_share')::numeric IS DISTINCT FROM round(23753.53 / 1784.63817, 8) THEN
    RAISE EXCEPTION 'FAIL (1) abgeleiteter Preis: %', v_p; END IF;
  SELECT payload INTO v_p FROM finance.import_staging WHERE batch_id = v_batch AND row_no = 2;
  IF (v_p->>'price_per_share')::numeric IS DISTINCT FROM 98.50 OR v_p ? 'average_purchase_price' THEN
    RAISE EXCEPTION 'FAIL (2) Alias: %', v_p; END IF;
  RAISE NOTICE 'PASS (1) Gesamt-Einstand -> Stueckpreis (DB); (2) Durchschnittskurs als Alias';

  -- (3)
  v_res := finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (3) bundle: %', v_res; END IF;
  IF jsonb_array_length(v_res->'positions') <> 2 THEN RAISE EXCEPTION 'FAIL (3) positions: %', v_res; END IF;
  SELECT x INTO v_pos FROM jsonb_array_elements(v_res->'positions') x WHERE x->>'isin' = 'IE00BK5BQT80';
  IF v_pos->>'provider_symbol' IS DISTINCT FROM 'VWCE.DE' OR (v_pos->>'holding_id') IS NULL
     OR v_pos ? 'asset_class' IS FALSE THEN
    RAISE EXCEPTION 'FAIL (3) Position: %', v_pos; END IF;
  RAISE NOTICE 'PASS (3) provider_symbol an der Position, positions[] im Bundle-Return';

  -- (4)
  IF NOT EXISTS (SELECT 1 FROM finance.depot_holdings_overview WHERE holding_id = (v_pos->>'holding_id')::int) THEN
    RAISE EXCEPTION 'FAIL (4): depot_holdings_overview.holding_id fehlt'; END IF;
  RAISE NOTICE 'PASS (4) depot_holdings_overview.holding_id';

  -- (5) 2026-10-23: Notierung nur in Fremdwaehrung (provider_currency aus tool_commit_import) -> quote_currency der
  --     EUR-Position, Einstand bleibt EUR; die Uebersicht zeigt Kurs-Waehrung + Anlageklasse-Spalte, market_value_eur
  --     rechnet per FX um; ein genannter Kaufkurs-quote_currency geht vor.
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('USD', 2) ON CONFLICT (code) DO NOTHING;
  INSERT INTO finance.fx_rates (base_currency, quote_currency, as_of, rate) VALUES ('EUR', 'USD', CURRENT_DATE, 1.10)
    ON CONFLICT DO NOTHING;
  v_res := finance.fn_import_stage(jsonb_build_object('source','vision','rows', jsonb_build_array(
    jsonb_build_object('entity_type','stock_buy','depot','__t_ids_depot__','isin','US84615Q1099','name','Raumfahrt',
                       'shares','2','price_per_share','100','provider_symbol','spcx','provider_currency','usd'))));
  IF (v_res->>'valid')::int <> 1 THEN RAISE EXCEPTION 'FAIL (5) stage: %', v_res; END IF;
  v_res := finance.fn_import_bundle(jsonb_build_object('batch_id', v_res->>'batch_id'));
  SELECT x INTO v_pos FROM jsonb_array_elements(v_res->'positions') x WHERE x->>'isin' = 'US84615Q1099';
  IF v_pos->>'quote_currency' IS DISTINCT FROM 'USD' OR v_pos->>'provider_symbol' IS DISTINCT FROM 'SPCX'
     OR (SELECT currency FROM finance.depot_holdings WHERE id = (v_pos->>'holding_id')::int) IS DISTINCT FROM 'EUR'
     OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = (v_pos->>'holding_id')::int) <> 100 THEN
    RAISE EXCEPTION 'FAIL (5) Position: % / %', v_pos, v_res; END IF;
  INSERT INTO finance.market_prices (symbol, as_of, price, currency) VALUES ('US84615Q1099', CURRENT_DATE, 110, 'USD');
  IF (SELECT price_currency FROM finance.depot_holdings_overview WHERE holding_id = (v_pos->>'holding_id')::int) IS DISTINCT FROM 'USD'
     OR (SELECT market_value_eur FROM finance.depot_holdings_overview WHERE holding_id = (v_pos->>'holding_id')::int) IS NULL
     OR NOT EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'finance'
                    AND table_name = 'depot_holdings_overview' AND column_name = 'asset_class') THEN
    RAISE EXCEPTION 'FAIL (5) Uebersicht: %', (SELECT row_to_json(o) FROM finance.depot_holdings_overview o
                                               WHERE holding_id = (v_pos->>'holding_id')::int); END IF;
  RAISE NOTICE 'PASS (5) Fremdwaehrungs-Notierung -> quote_currency, Einstand EUR, Bewertung per FX';
END $$;

ROLLBACK;
