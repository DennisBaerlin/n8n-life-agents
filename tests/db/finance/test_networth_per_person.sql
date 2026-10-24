-- tests/db/finance/test_networth_per_person.sql
-- Multi-Member WS-3a (Custodial-Scope): finance.networth_by_asset_class traegt jetzt die
-- owner_person_id-Dimension (je UNION-Zweig). Drei Sichten auf EINE Datenbasis:
--   T1 Gesamt-Familie (alle Owner, inkl. Kind) · T2 Eltern-/FIRE-Pool (role='child' RAUS,
--   Haushalt-NULL + partner DRIN) · T3 Pro-Kind (owner_person_id = Kind-Slug).
-- Kind-Erkennung ROLLEN-basiert ueber core.fn_household_persons() (DEFINER-Fenster) — keine
-- neue Spalte. Pin: mehrere Owner je asset_class -> per-Klasse-Read MUSS summieren (kein LIMIT 1).
BEGIN;

DO $$
DECLARE
  v_kid_cash INT; v_kid_depot INT; v_hh_cash INT; v_p_cash INT; v_hh_depot INT;
  v_goal INT;
  v_t1 NUMERIC; v_fire NUMERIC; v_kid NUMERIC; v_partner NUMERIC;
  v_sp500_t1 NUMERIC; v_sp500_fire NUMERIC; v_val NUMERIC; v_owner TEXT;
BEGIN
  -- ---------- Personen (projiziertes Read-Model; im Test direkt befuellt) ----------
  INSERT INTO agent.persons (person_id, full_name, role) VALUES
    ('nwp_kid',     'Kind Beispiel',    'child'),
    ('nwp_partner', 'Partner Beispiel', 'partner');

  -- ---------- Konten ----------
  -- Haushalts-Cash (owner NULL = gemeinsam), Earmark 2000 -> netto 8000
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__nwp_hh_cash__','cash','EUR','active', NULL) RETURNING id INTO v_hh_cash;
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_hh_cash;

  -- Partner-Cash (owner partner) 4000 — Partner bleibt im FIRE-Pool (Paar-Vermoegen)
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__nwp_p_cash__','cash','EUR','active', 'nwp_partner') RETURNING id INTO v_p_cash;
  UPDATE finance.account_balances SET balance = 4000 WHERE account_id = v_p_cash;

  -- Haushalts-Depot (owner NULL) mit sp500-Holding Buchwert 500
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__nwp_hh_depot__','stocks_depot','EUR','active', v_hh_cash, NULL) RETURNING id INTO v_hh_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_hh_depot,'NWP00000001','NWPHH','HH ETF', 5, 100, 'EUR', 'sp500');

  -- Kind-Custodial-Depot (owner Kind) mit sp500-Holding Buchwert 1000 — gehoert dem Kind
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__nwp_kid_cash__','cash','EUR','active', 'nwp_kid') RETURNING id INTO v_kid_cash;
  -- (Kind-Settlement-Cash bewusst Saldo 0 -> kein Cash-Beitrag, nur das Depot zaehlt)
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id, owner_person_id)
    VALUES ('__nwp_kid_depot__','stocks_depot','EUR','active', v_kid_cash, 'nwp_kid') RETURNING id INTO v_kid_depot;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
    VALUES (v_kid_depot,'NWP00000002','NWPKID','Kind ETF', 10, 100, 'EUR', 'sp500');

  -- WS-B: Earmark-Netting (savings_goal_allocations) entfallen -> Haushalts-Cash = BRUTTO-Saldo 10000.

  -- ===== T1: Gesamt-Familie (alle Owner kollabiert) — Kind IST drin =====
  SELECT COALESCE(sum(value_eur),0) INTO v_t1 FROM finance.networth_by_asset_class WHERE tradeable;
  IF v_t1 IS DISTINCT FROM 15500 THEN
    RAISE EXCEPTION 'FAIL [T1]: erwartet 15500 (hh_cash 10000 + partner 4000 + hh_depot 500 + kid_depot 1000), got %', v_t1; END IF;
  RAISE NOTICE 'PASS [T1 Gesamt-Familie inkl. Kind-Depot = 15500]';

  -- ===== T2: Eltern-/FIRE-Pool (role='child' RAUS, NULL+partner DRIN) =====
  SELECT COALESCE(sum(n.value_eur),0) INTO v_fire
  FROM finance.networth_by_asset_class n
  LEFT JOIN core.fn_household_persons() p ON p.person_id = n.owner_person_id
  WHERE n.tradeable AND p.role IS DISTINCT FROM 'child';
  IF v_fire IS DISTINCT FROM 14500 THEN
    RAISE EXCEPTION 'FAIL [T2 FIRE]: erwartet 14500 (Kind-Depot 1000 RAUS), got %', v_fire; END IF;
  RAISE NOTICE 'PASS [T2 FIRE-Pool ohne Kind-Depot = 14500 (Haushalt+Partner drin)]';

  -- ===== T3: Pro-Kind-Sub-Portfolio =====
  SELECT COALESCE(sum(value_eur),0) INTO v_kid FROM finance.networth_by_asset_class WHERE owner_person_id = 'nwp_kid';
  IF v_kid IS DISTINCT FROM 1000 THEN RAISE EXCEPTION 'FAIL [T3 Kind]: erwartet 1000, got %', v_kid; END IF;
  RAISE NOTICE 'PASS [T3 Pro-Kind-Sub-Portfolio = 1000]';

  -- Partner-Vermoegen bleibt im Pool (role=partner, NICHT child)
  SELECT COALESCE(sum(value_eur),0) INTO v_partner FROM finance.networth_by_asset_class WHERE owner_person_id = 'nwp_partner';
  IF v_partner IS DISTINCT FROM 4000 THEN RAISE EXCEPTION 'FAIL [Partner]: erwartet 4000, got %', v_partner; END IF;
  RAISE NOTICE 'PASS [Partner-Vermoegen 4000 (bleibt im FIRE-Pool)]';

  -- ===== Pin: mehrere Owner je asset_class (sp500 = Haushalt 500 + Kind 1000) =====
  -- T1 sp500 = 1500 (beide Owner), FIRE sp500 = 500 (Kind raus). Ein LIMIT-1-Read wuerde hier brechen.
  SELECT COALESCE(sum(value_eur),0) INTO v_sp500_t1 FROM finance.networth_by_asset_class WHERE asset_class = 'sp500';
  IF v_sp500_t1 IS DISTINCT FROM 1500 THEN RAISE EXCEPTION 'FAIL [sp500 T1]: erwartet 1500 (Haushalt 500 + Kind 1000), got %', v_sp500_t1; END IF;
  SELECT COALESCE(sum(n.value_eur),0) INTO v_sp500_fire
  FROM finance.networth_by_asset_class n
  LEFT JOIN core.fn_household_persons() p ON p.person_id = n.owner_person_id
  WHERE n.tradeable AND n.asset_class = 'sp500' AND p.role IS DISTINCT FROM 'child';
  IF v_sp500_fire IS DISTINCT FROM 500 THEN RAISE EXCEPTION 'FAIL [sp500 FIRE]: erwartet 500 (nur Haushalt, Kind raus), got %', v_sp500_fire; END IF;
  RAISE NOTICE 'PASS [Pin: sp500 mehrere Owner — T1=1500, FIRE=500 (per-Klasse summiert, nicht LIMIT 1)]';

  -- ===== Owner-Vererbung: Haushalts-Cash brutto 10000 unter owner NULL (WS-B: kein Earmark-Netting mehr) =====
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE bucket = 'cash' AND owner_person_id IS NULL;
  IF v_val IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 'FAIL [Owner/Cash]: Haushalts-Cash brutto erwartet 10000, got %', v_val; END IF;
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE bucket = 'cash' AND owner_person_id = 'nwp_partner';
  IF v_val IS DISTINCT FROM 4000 THEN RAISE EXCEPTION 'FAIL [Partner-Cash]: erwartet 4000, got %', v_val; END IF;
  RAISE NOTICE 'PASS [Cash brutto per-Konto, Owner-Zuordnung bleibt (Haushalt-NULL 10000, Partner 4000)]';
END $$;

ROLLBACK;
