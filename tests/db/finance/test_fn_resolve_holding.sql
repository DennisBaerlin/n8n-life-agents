-- tests/db/finance/test_fn_resolve_holding.sql
-- Testet fn_resolve_holding: Holding im Depot finden (found=TRUE) bzw. found=FALSE bei neuer ISIN.
BEGIN;

DO $$
DECLARE v_settle INT; v_depot INT; v_hid INT; v_rid INT; v_found BOOLEAN;
BEGIN
  INSERT INTO finance.accounts (name, account_type, status)
    VALUES ('__rh_settle__', 'cash', 'active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, status, settlement_account_id)
    VALUES ('__rh_depot__', 'stocks_depot', 'active', v_settle) RETURNING id INTO v_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency)
    VALUES (v_depot, 'TESTISIN001', 'TST', 'Test Holding', 0, NULL, 'EUR') RETURNING id INTO v_hid;

  -- vorhanden -> found=TRUE, id passt (3-arg: isin + symbol)
  -- (Spalten qualifizieren: 'found' kollidiert sonst mit der PL/pgSQL-Spezialvariable FOUND)
  SELECT r.id, r.found INTO v_rid, v_found FROM finance.fn_resolve_holding(v_depot, 'TESTISIN001', 'TST') AS r;
  IF v_found IS DISTINCT FROM TRUE OR v_rid IS DISTINCT FROM v_hid THEN
    RAISE EXCEPTION 'FAIL resolve_holding [found]: found=%, id=% (erwartet %)', v_found, v_rid, v_hid;
  END IF;

  -- unbekannte ISIN -> found=FALSE
  SELECT r.found INTO v_found FROM finance.fn_resolve_holding(v_depot, 'UNKNOWN_ISIN', 'UNK') AS r;
  IF v_found IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FAIL resolve_holding [not found]: found=% (erwartet FALSE)', v_found;
  END IF;

  RAISE NOTICE 'PASS fn_resolve_holding: found=TRUE (id=%) + found=FALSE fuer neue ISIN', v_hid;
END $$;

ROLLBACK;
