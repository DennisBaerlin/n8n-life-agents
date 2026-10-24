-- tests/db/finance/test_networth_by_asset_class.sql
-- WS2b/WS3 (Core-Advisor-Engine): View finance.networth_by_asset_class — Gesamtvermoegen nach Anlageklasse.
-- Prueft die Klassen-Herkunft je Entitaet (Owner-Lock):
--   Depot via asset_class-Tag (Marktwert + Buchwert-Fallback) · Cash = BRUTTO-balance · WS3: Festgeld = EIGENE
--   NICHT-handelbare Klasse (bucket='fixed_deposit', tradeable=false, raus aus dem Rebalancing-Nenner) · p2p
--   eigene Klasse · loan negativ · REINE Depot-Konten zaehlen NICHT (Doppelzaehl-Schutz) · real_estate/pension
--   abgeleitet · tradeable-Flag (nur depot+cash).
-- WS-B: das Earmark-Netting (savings_goal_allocations) ist mit dem Tabellen-DROP entfallen -> Cash/Festgeld
--   zeigen den BRUTTO-Saldo; das FIRE-Topf-Netting ist bewusst nach BACKLOG verschoben (Reserve-Fundament zuerst).
BEGIN;

DO $$
DECLARE
  v_cash INT; v_depot INT; v_p2p INT; v_loan INT; v_fd INT;
  v_h1 INT; v_h2 INT; v_h3 INT;
  v_val NUMERIC; v_trad BOOLEAN; v_trade_sum NUMERIC;
BEGIN
  -- ---------- Konten ----------
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__nw_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__nw_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__nw_p2p__','p2p','EUR','active') RETURNING id INTO v_p2p;
  UPDATE finance.account_balances SET balance = 3000 WHERE account_id = v_p2p;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__nw_loan__','loan','EUR','active') RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -5000 WHERE account_id = v_loan;
  -- WS3: Festgeld 10000 (eigene Klasse, nicht handelbar; WS-B: brutto, kein Earmark-Abzug mehr)
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__nw_fd__','fixed_deposit','EUR','active','2030-12-31') RETURNING id INTO v_fd;
  UPDATE finance.account_balances SET balance = 10000 WHERE account_id = v_fd;

  -- ---------- Holdings (shares direkt gesetzt; ohne Buchung) ----------
  -- VWCE: Marktpreis 110 vorhanden -> Marktwert 5*110 = 550 (Tag sp500)
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_depot, 'IE00BK5BQT80','VWCE','Vanguard FTSE All-World', 5, 100, 'EUR', 'sp500') RETURNING id INTO v_h1;
  INSERT INTO finance.market_prices (symbol, isin, price, currency, as_of) VALUES ('VWCE','IE00BK5BQT80', 110, 'EUR', current_date);
  -- IWDA: KEIN Marktpreis -> Buchwert-Fallback 4*80 = 320 (Tag gold)
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_depot, 'IE00B4L5Y983','IWDA','iShares Core', 4, 80, 'EUR', 'gold') RETURNING id INTO v_h2;
  -- Ungetaggte Position -> asset_class NULL, zaehlt aber zum Vermoegen (null_tag-Report uebernimmt die fn)
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_depot, 'IE00B0M62Q58','SWDA','iShares 2', 2, 50, 'EUR', NULL) RETURNING id INTO v_h3;

  -- ---------- Assets ----------
  INSERT INTO finance.real_estate (name, current_value, status) VALUES ('__nw_re__', 300000, 'active');
  INSERT INTO finance.pension (name, pension_type, current_value, status) VALUES ('__nw_pen__','private', 50000, 'active');

  -- ===== Assertions =====
  -- sp500 depot, tradeable, Marktwert 550
  SELECT value_eur, tradeable INTO v_val, v_trad FROM finance.networth_by_asset_class WHERE asset_class = 'sp500';
  IF v_val IS DISTINCT FROM 550 OR v_trad IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [sp500]: erwartet 550/tradeable, got %/%', v_val, v_trad; END IF;
  RAISE NOTICE 'PASS [Depot sp500 Marktwert 550, tradeable]';

  -- gold depot, Buchwert-Fallback 320
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE asset_class = 'gold';
  IF v_val IS DISTINCT FROM 320 THEN RAISE EXCEPTION 'FAIL [gold fallback]: erwartet 320 (Buchwert), got %', v_val; END IF;
  RAISE NOTICE 'PASS [Depot gold Buchwert-Fallback 320]';

  -- ungetaggte Position erscheint (class NULL), Wert 2*50 = 100
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE bucket = 'depot' AND asset_class IS NULL;
  IF v_val IS DISTINCT FROM 100 THEN RAISE EXCEPTION 'FAIL [untagged]: erwartet 100, got %', v_val; END IF;
  RAISE NOTICE 'PASS [ungetaggte Depot-Position zaehlt (class NULL, 100)]';

  -- cash BRUTTO 10000, tradeable (WS-B: kein Earmark-Abzug mehr)
  SELECT value_eur, tradeable INTO v_val, v_trad FROM finance.networth_by_asset_class WHERE asset_class = 'cash';
  IF v_val IS DISTINCT FROM 10000 OR v_trad IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [cash brutto]: erwartet 10000/tradeable, got %/%', v_val, v_trad; END IF;
  RAISE NOTICE 'PASS [Cash brutto-balance 10000, tradeable]';

  -- p2p eigene Klasse, NICHT tradeable
  SELECT value_eur, tradeable INTO v_val, v_trad FROM finance.networth_by_asset_class WHERE asset_class = 'p2p';
  IF v_val IS DISTINCT FROM 3000 OR v_trad IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [p2p]: erwartet 3000/nicht-tradeable, got %/%', v_val, v_trad; END IF;
  RAISE NOTICE 'PASS [p2p eigene Klasse 3000, nicht handelbar]';

  -- WS3: Festgeld = EIGENE bucket-Klasse, NICHT tradeable, brutto 10000 (WS-B: kein Earmark-Abzug mehr)
  SELECT value_eur, tradeable INTO v_val, v_trad FROM finance.networth_by_asset_class WHERE bucket = 'fixed_deposit';
  IF v_val IS DISTINCT FROM 10000 OR v_trad IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [fixed_deposit]: erwartet 10000/nicht-tradeable, got %/%', v_val, v_trad; END IF;
  RAISE NOTICE 'PASS [WS3: Festgeld eigene Klasse 10000 (brutto), nicht handelbar]';

  -- WS3: Festgeld NICHT mehr in der cash-Klasse (cash bleibt 10000, ohne die 10000 Festgeld)
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE asset_class = 'cash';
  IF v_val IS DISTINCT FROM 10000 THEN RAISE EXCEPTION 'FAIL [cash ohne Festgeld]: erwartet 10000 (ohne das Festgeld), got %', v_val; END IF;
  RAISE NOTICE 'PASS [WS3: cash-Klasse ohne Festgeld]';

  -- WS3: tradeable-Summe (Rebalancing-Nenner) schliesst Festgeld aus = depot (550+320+100=970) + cash 10000 = 10970
  SELECT COALESCE(sum(value_eur),0) INTO v_trade_sum FROM finance.networth_by_asset_class WHERE tradeable;
  IF v_trade_sum IS DISTINCT FROM 10970 THEN RAISE EXCEPTION 'FAIL [tradeable sum]: erwartet 10970 (depot 970 + cash 10000, OHNE Festgeld), got %', v_trade_sum; END IF;
  RAISE NOTICE 'PASS [WS3: tradeable-Summe schliesst Festgeld aus (10970)]';

  -- loan negativ
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE asset_class = 'loan';
  IF v_val IS DISTINCT FROM -5000 THEN RAISE EXCEPTION 'FAIL [loan]: erwartet -5000, got %', v_val; END IF;
  RAISE NOTICE 'PASS [loan Verbindlichkeit -5000]';

  -- real_estate / pension abgeleitet
  SELECT value_eur INTO v_val FROM finance.networth_by_asset_class WHERE asset_class = 'real_estate';
  IF v_val IS DISTINCT FROM 300000 THEN RAISE EXCEPTION 'FAIL [real_estate]: erwartet 300000, got %', v_val; END IF;
  SELECT value_eur, tradeable INTO v_val, v_trad FROM finance.networth_by_asset_class WHERE asset_class = 'pension';
  IF v_val IS DISTINCT FROM 50000 OR v_trad IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [pension]: erwartet 50000/nicht-tradeable, got %/%', v_val, v_trad; END IF;
  RAISE NOTICE 'PASS [real_estate 300000 + pension 50000 abgeleitet, nicht handelbar]';

  -- REINES Depot-Konto erscheint NICHT als eigene Zeile (Doppelzaehl-Schutz: Wert steckt in den Holdings)
  IF EXISTS (SELECT 1 FROM finance.networth_by_asset_class WHERE bucket = 'cash' AND value_eur = 0) THEN
    RAISE EXCEPTION 'FAIL [depot account]: reines Depot-Konto darf nicht als Cash-Zeile auftauchen';
  END IF;
  RAISE NOTICE 'PASS [reines Depot-Konto nicht in der View (Doppelzaehl-Schutz)]';
END $$;

ROLLBACK;
