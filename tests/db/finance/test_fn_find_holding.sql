-- tests/db/finance/test_fn_find_holding.sql
-- finance.fn_find_holding (Paket DB-ist-das-Gesetz S8): Position per Depot-NAME + ISIN oder Symbol, statt dass das Modell
--   vorher holding_id per postgres_select nachschlaegt. Konsumenten: tool_book_stock_sell, tool_set_holding.
--   (1) per Symbol ohne Gross-/Kleinschreibung (auch bei Aktie mit ISIN) -> ok + holding_id, depot, settlement, Stueck
--   (2) per ISIN -> ok
--   (3) unbekannte Position -> ok:false holding_not_found, candidates = Positionen des Depots
--   (4) unbekanntes Depot -> ok:false depot_not_found (candidates aus fn_resolve_account)
BEGIN;

DO $$
DECLARE v_r jsonb; v_settle int; v_depot int; v_hold int;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__fh_settle__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__fh Depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  v_hold := (finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot, 'settlement_id', v_settle,
              'isin', 'IE00B4L5Y983', 'symbol', 'IWDA', 'name', 'iShares MSCI World', 'shares', 3, 'price_per_share', 100,
              'order_fee', 0, 'transaction_date', '2026-10-01'))->>'holding_id')::int;

  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh depot__', 'symbol', 'iwda'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'holding_id')::int IS DISTINCT FROM v_hold
     OR (v_r->>'settlement_account_id')::int IS DISTINCT FROM v_settle OR (v_r->>'available_shares')::numeric IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL find_holding [Symbol ci]: %', v_r; END IF;

  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'isin', 'IE00B4L5Y983', 'symbol', ''));
  IF (v_r->>'holding_id')::int IS DISTINCT FROM v_hold THEN RAISE EXCEPTION 'FAIL find_holding [ISIN]: %', v_r; END IF;

  -- ISIN ohne Treffer, aber Symbol passt -> Rueckfall aufs Symbol (das Modell fuellte eine falsche/fremde ISIN)
  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'isin', 'IE00BK5BQT80', 'symbol', 'IWDA'));
  IF (v_r->>'holding_id')::int IS DISTINCT FROM v_hold THEN RAISE EXCEPTION 'FAIL find_holding [ISIN-Rueckfall Symbol]: %', v_r; END IF;
  -- gespeicherte ISIN in Kleinbuchstaben wird trotzdem gefunden
  UPDATE finance.depot_holdings SET isin = lower(isin) WHERE id = v_hold;
  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'isin', 'IE00B4L5Y983'));
  IF (v_r->>'holding_id')::int IS DISTINCT FROM v_hold THEN RAISE EXCEPTION 'FAIL find_holding [ISIN ci]: %', v_r; END IF;
  UPDATE finance.depot_holdings SET isin = upper(isin) WHERE id = v_hold;

  -- position = aktuelles Symbol ODER ISIN in einem Feld (set_holding)
  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'position', 'ie00b4l5y983'));
  IF (v_r->>'holding_id')::int IS DISTINCT FROM v_hold OR v_r->>'name' IS DISTINCT FROM 'iShares MSCI World' THEN
    RAISE EXCEPTION 'FAIL find_holding [position = ISIN]: %', v_r; END IF;
  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'position', 'IWDA'));
  IF (v_r->>'holding_id')::int IS DISTINCT FROM v_hold THEN RAISE EXCEPTION 'FAIL find_holding [position = Symbol]: %', v_r; END IF;

  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh Depot__', 'symbol', 'VWCE'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'holding_not_found'
     OR jsonb_array_length(v_r->'candidates') <> 1 THEN
    RAISE EXCEPTION 'FAIL find_holding [unbekannte Position -> Kandidaten]: %', v_r; END IF;

  v_r := finance.fn_find_holding(jsonb_build_object('depot_name', '__fh_nope__', 'symbol', 'IWDA'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'depot_not_found' THEN
    RAISE EXCEPTION 'FAIL find_holding [unbekanntes Depot]: %', v_r; END IF;

  RAISE NOTICE 'PASS fn_find_holding [Symbol ci, ISIN, Position/Depot unbekannt -> ok:false + Kandidaten]';
END $$;

ROLLBACK;
