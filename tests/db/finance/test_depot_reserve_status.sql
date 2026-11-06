-- tests/db/finance/test_depot_reserve_status.sql
-- WS-B Stufe 1 (Phase S): View finance.depot_reserve_status — der Deckungs-Waechter der DEPOT-Reserve.
-- Je AKTIVEM Depot-Konto: Marktwert (shares x juengstem Kurs, EUR, via depot_holdings_overview-Roll-up) vs.
-- Σ savings_goal_reserve_entries.delta_native ueber AKTIVE Ziele.
--   breach = COALESCE(market_value,0) < reserved  (reserved>0). NULL-Preis -> COALESCE 0 -> breach=TRUE
--     (3-wertige Logik vermieden: ein nicht ermittelbarer Marktwert deckt NICHTS, nie still FALSE).
--   shortfall = GREATEST(reserved - COALESCE(market_value,0), 0).
-- Ein completed/cancelled-Ziel faellt aus dem status='active'-Join -> gibt seine Depot-Reserve frei.
BEGIN;

DO $$
DECLARE
  v_settle INT; v_d1 INT; v_d2 INT; v_d3 INT; v_gA INT; v_gB INT; v_gIn INT;
  v_mv NUMERIC; v_res NUMERIC; v_short NUMERIC; v_breach BOOLEAN;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__drs_settle__','cash','EUR','active') RETURNING id INTO v_settle;
  -- Depot 1: Marktwert 600 (5 x 120). Depot 2: gehalten, KEIN Kurs -> Marktwert NULL. Depot 3: Marktwert 1000.
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__drs_depot1__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_d1;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__drs_depot2__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_d2;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__drs_depot3__','stocks_depot','EUR','active', v_settle) RETURNING id INTO v_d3;

  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_d1, 'DRSX', 'D1 Wert', 5, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DRSX', 120, 'EUR', current_date);  -- mv 600
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_d2, 'DRSY', 'D2 Wert', 3, 100, 'EUR');   -- KEIN Kurs -> mv NULL
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_d3, 'DRSZ', 'D3 Wert', 10, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('DRSZ', 100, 'EUR', current_date);  -- mv 1000

  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drs_gA__', 9000, current_date + 365, 'active') RETURNING id INTO v_gA;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drs_gB__', 9000, current_date + 365, 'active') RETURNING id INTO v_gB;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status)
    VALUES ('__drs_gIn__', 9000, current_date + 365, 'completed') RETURNING id INTO v_gIn;

  -- Depot 1: reserviert 400 (gegen mv 600) -> GEDECKT, kein breach, shortfall 0.
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES (v_gA, v_d1, 400, 'manual');
  -- Depot 3: reserviert 600 (gA) + 700 (gB) = 1300 (gegen mv 1000) -> UNTERDECKT, shortfall 300.
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES (v_gA, v_d3, 600, 'manual'), (v_gB, v_d3, 700, 'manual');
  -- Depot 2: reserviert 200, aber Marktwert NULL (kein Kurs) -> breach=TRUE, shortfall 200.
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES (v_gA, v_d2, 200, 'manual');
  -- Depot 1 zusaetzlich: reserviert 5000 fuer ein COMPLETED-Ziel -> darf NICHT zaehlen (Join active).
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind)
    VALUES (v_gIn, v_d1, 5000, 'manual');

  -- (1) Depot 1: gedeckt (reserved 400 <= mv 600), completed-Ziel ausgeschlossen.
  SELECT market_value, reserved, shortfall, breach INTO v_mv, v_res, v_short, v_breach
    FROM finance.depot_reserve_status WHERE account_id = v_d1;
  IF v_mv IS DISTINCT FROM 600 THEN RAISE EXCEPTION 'FAIL [1 mv]: erwartet 600, got %', v_mv; END IF;
  IF v_res IS DISTINCT FROM 400 THEN RAISE EXCEPTION 'FAIL [1 reserved]: erwartet 400 (completed-Ziel 5000 ausgeschlossen), got %', v_res; END IF;
  IF v_breach IS DISTINCT FROM false OR v_short IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [1 cover]: erwartet kein breach / shortfall 0, got %/%', v_breach, v_short; END IF;
  RAISE NOTICE 'PASS [1: Depot gedeckt (400<=600), completed-Ziel-Reserve 5000 NICHT gezaehlt -> kein breach]';

  -- (2) Depot 3: unterdeckt (reserved 1300 > mv 1000) -> breach, shortfall 300.
  SELECT market_value, reserved, shortfall, breach INTO v_mv, v_res, v_short, v_breach
    FROM finance.depot_reserve_status WHERE account_id = v_d3;
  IF v_mv IS DISTINCT FROM 1000 OR v_res IS DISTINCT FROM 1300 THEN RAISE EXCEPTION 'FAIL [2 setup]: mv % reserved %', v_mv, v_res; END IF;
  IF v_breach IS DISTINCT FROM true OR v_short IS DISTINCT FROM 300 THEN RAISE EXCEPTION 'FAIL [2 breach]: erwartet breach=true / shortfall 300, got %/%', v_breach, v_short; END IF;
  RAISE NOTICE 'PASS [2: Depot unterdeckt (1300>1000, 2 Ziele gepoolt) -> breach, shortfall 300]';

  -- (3) Depot 2: Marktwert NULL (kein Kurs) -> breach=TRUE (Deckung 0), shortfall = reserved 200. NIE still FALSE.
  --     WP-3c: fx_missing=TRUE (Deckung nicht ermittelbar) — trennt „Kurs fehlt" von „echt unterdeckt".
  DECLARE v_fxm BOOLEAN; BEGIN
    SELECT market_value, reserved, shortfall, breach, fx_missing INTO v_mv, v_res, v_short, v_breach, v_fxm
      FROM finance.depot_reserve_status WHERE account_id = v_d2;
    IF v_mv IS NOT NULL THEN RAISE EXCEPTION 'FAIL [3 mv NULL]: erwartet market_value NULL (kein Kurs), got %', v_mv; END IF;
    IF v_breach IS DISTINCT FROM true OR v_short IS DISTINCT FROM 200 THEN RAISE EXCEPTION 'FAIL [3 null-price breach]: erwartet breach=true / shortfall 200, got %/%', v_breach, v_short; END IF;
    IF v_fxm IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [3 fx_missing]: erwartet TRUE (Marktwert nicht ermittelbar), got %', v_fxm; END IF;
    RAISE NOTICE 'PASS [3: NULL-Preis -> breach=TRUE + fx_missing=TRUE (Deckung nicht ermittelbar, nicht still FALSE)]';
  END;
  -- Depot 1 (gedeckt, Kurs vorhanden) -> fx_missing=FALSE
  IF (SELECT fx_missing FROM finance.depot_reserve_status WHERE account_id = v_d1) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [3b fx_missing]: gedecktes Depot mit Kurs muss fx_missing=FALSE haben'; END IF;
  RAISE NOTICE 'PASS [3b: gedecktes Depot mit Kurs -> fx_missing=FALSE]';
END $$;

ROLLBACK;
