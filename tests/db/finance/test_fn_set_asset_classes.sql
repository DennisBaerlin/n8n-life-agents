-- tests/db/finance/test_fn_set_asset_classes.sql
-- fn_set_asset_classes: mehrere Positionen in EINEM atomaren Schritt (Owner-Entscheid 2026-10-23, Berater-Werkzeug)
--   (1) zwei Positionen (Symbol bzw. ISIN), card_lines je Position, nur asset_class geaendert
--   (2) atomar: eine unbekannte Position / falsches Format / doppelte Position -> NICHTS geschrieben
--   (3) outside_plan erlaubt
BEGIN;

DO $$
DECLARE v_cash INT; v_depot INT; v_r JSONB; v_h1 INT; v_h2 INT; v_avg NUMERIC;
BEGIN
  v_cash  := (finance.fn_create_account('{"name":"__t_sac_cash__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot := (finance.fn_create_account(jsonb_build_object('name','__t_sac_depot__','account_type','stocks_depot','settlement_id', v_cash))->>'account_id')::int;
  v_h1 := (finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'isin','IE00BYML9W36',
            'name','S&P 500 (Dist)', 'shares', 2, 'price_per_share', 50, 'existing_position', true))->>'holding_id')::int;
  v_h2 := (finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_cash, 'isin','US84615Q1099',
            'symbol','SPCX', 'name','Raumfahrt', 'shares', 1, 'price_per_share', 120, 'existing_position', true))->>'holding_id')::int;
  SELECT average_purchase_price INTO v_avg FROM finance.depot_holdings WHERE id = v_h1;

  -- (2) atomar: Zeile 2 unbekannt -> nichts geschrieben
  v_r := finance.fn_set_asset_classes(jsonb_build_object('assignments', jsonb_build_array(
           jsonb_build_object('depot_name','__t_sac_depot__','position','IE00BYML9W36','asset_class','sp500'),
           jsonb_build_object('depot_name','__t_sac_depot__','position','GIBTSNICHT','asset_class','x'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR (SELECT asset_class FROM finance.depot_holdings WHERE id = v_h1) IS NOT NULL
     OR v_r->'errors'->0->>'index' IS DISTINCT FROM '2' THEN
    RAISE EXCEPTION 'FAIL (2) atomar: %', v_r; END IF;
  -- Kandidaten der Fehlzeilen stehen zusaetzlich oben (das Tool-Gate reicht nur reason + candidates durch)
  IF jsonb_typeof(v_r->'candidates') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_r->'candidates') <> jsonb_array_length(COALESCE(v_r->'errors'->0->'candidates', '[]'::jsonb)) THEN
    RAISE EXCEPTION 'FAIL (2) candidates oben: %', v_r; END IF;
  v_r := finance.fn_set_asset_classes(jsonb_build_object('assignments', jsonb_build_array(
           jsonb_build_object('depot_name','__t_sac_depot__','position','SPCX','asset_class','Einzel Aktien'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%lowercase key%' THEN RAISE EXCEPTION 'FAIL (2) Format: %', v_r; END IF;
  v_r := finance.fn_set_asset_classes(jsonb_build_object('assignments', jsonb_build_array(
           jsonb_build_object('depot_name','__t_sac_depot__','position','SPCX','asset_class','a'),
           jsonb_build_object('depot_name','__t_sac_depot__','position','us84615q1099','asset_class','b'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'reason' NOT LIKE '%twice%' THEN RAISE EXCEPTION 'FAIL (2) doppelt: %', v_r; END IF;
  IF (SELECT count(*) FROM finance.fn_set_asset_classes('{"assignments":[]}'::jsonb) x) <> 1
     OR (finance.fn_set_asset_classes('{"assignments":[]}'::jsonb)->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL (2) leere Liste'; END IF;
  RAISE NOTICE 'PASS (2) atomar: unbekannt / Format / doppelt / leer -> nichts geschrieben';

  -- (1) + (3)
  v_r := finance.fn_set_asset_classes(jsonb_build_object('assignments', jsonb_build_array(
           jsonb_build_object('depot_name','__t_sac_depot__','position','IE00BYML9W36','asset_class','sp500'),
           jsonb_build_object('depot_name','__t_sac_depot__','position','spcx','asset_class','outside_plan'))));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(v_r->'updated') <> 2
     OR jsonb_array_length(v_r->'card_lines') <> 2
     OR (SELECT asset_class FROM finance.depot_holdings WHERE id = v_h1) IS DISTINCT FROM 'sp500'
     OR (SELECT asset_class FROM finance.depot_holdings WHERE id = v_h2) IS DISTINCT FROM 'outside_plan'
     OR (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = v_h1) IS DISTINCT FROM v_avg
     OR (SELECT shares FROM finance.depot_holdings WHERE id = v_h1) <> 2 THEN
    RAISE EXCEPTION 'FAIL (1) Zuordnung: %', v_r; END IF;
  IF v_r->'card_lines'->1->'value'->>'value' IS DISTINCT FROM 'finance.tpl.asset_class_outside' THEN
    RAISE EXCEPTION 'FAIL (3) Kartenzeile outside_plan: %', v_r->'card_lines'; END IF;
  RAISE NOTICE 'PASS (1) zwei Positionen, nur asset_class; (3) outside_plan';
END $$;

ROLLBACK;
