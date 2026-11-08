-- tests/db/finance/test_recalc_depot.sql
-- Zweitrechnung Depot: Einstandspreis (gleitender Durchschnitt) und Depot-Rendite, Erwartungswerte unabhaengig
-- hergeleitet (Durchschnitt schriftlich, XIRR mit eigenem Newton in PowerShell).
-- Fachregel Einstand: Durchschnittskostenmethode, Gebuehr gehoert zur Kostenbasis; ein Verkauf mindert die Kostenbasis
--   anteilig, der Durchschnitt bleibt (Hinweis: steuerlich gilt in Deutschland FIFO, § 20 Abs. 4 Satz 7 EStG; die
--   App zeigt nur den Einstand, keine Steuer).
--   Kauf 10 x 80 + 5 = 805 -> 80,50; Kauf 5 x 100 + 5 = 505 -> 1.310 / 15 = 87,3333; Verkauf 6 -> Kosten
--   1.310 x 9/15 = 786, Durchschnitt unveraendert; Kauf 4 x 90 + 2 = 362 -> 1.148 / 13 = 88,30769231
-- Fachregel Rendite: XIRR Act/365 aus Anlegersicht (Kauf -, Verkauf/Dividende +, Endwert +), siehe test_recalc_xirr.
--   Fluesse 10.09.2025 -805, 15.12.2025 -505, 31.03.2026 +657 (6 x 110 - 3), 15.05.2026 +24 Dividende,
--   01.06.2026 -362, Endwert 30.10.2026 13 x 120 = 1.560 -> 415 Tage, 49,741452 % p.a. -> 49,74
-- Self-contained, Werte erfunden.
BEGIN;

DO $$
DECLARE
  v_giro int; v_dep int; h int; v jsonb; v_row jsonb;
BEGIN
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active' AND account_type IN ('stocks_depot', 'crypto_depot');
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__recalc_dgiro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__recalc_dep__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, currency)
    VALUES (v_dep, 'RCL00000001', 'RCLX1', 'Recalc Welt', 'EUR') RETURNING id INTO h;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee) VALUES
    (v_giro, -805, '2025-09-10', 'buy',  h, 10, 5),
    (v_giro, -505, '2025-12-15', 'buy',  h,  5, 5),
    (v_giro,  657, '2026-03-31', 'sell', h, -6, 3),
    (v_giro, -362, '2026-06-01', 'buy',  h,  4, 2);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id) VALUES
    (v_giro, 24, '2026-05-15', 'dividend', h);
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES ('RCLX1', 120, 'EUR', '2026-10-30');

  IF (SELECT average_purchase_price FROM finance.depot_holdings WHERE id = h) IS DISTINCT FROM 88.30769231
     OR (SELECT shares FROM finance.depot_holdings WHERE id = h) IS DISTINCT FROM 13 THEN
    RAISE EXCEPTION 'FAIL [1] Einstand: %', (SELECT row(shares, average_purchase_price) FROM finance.depot_holdings WHERE id = h); END IF;
  RAISE NOTICE 'PASS [1] Einstand gleitender Durchschnitt 88,30769231';

  v := finance.fn_depot_performance('{"as_of":"2026-10-30"}');
  SELECT r INTO v_row FROM jsonb_array_elements(v->'rows') r WHERE (r->>'account_id')::int = v_dep;
  IF (v_row->>'value_eur')::numeric IS DISTINCT FROM 1560.00 OR (v_row->>'period_days')::int IS DISTINCT FROM 415
     OR (v_row->>'return_pa_pct')::numeric IS DISTINCT FROM 49.74 THEN
    RAISE EXCEPTION 'FAIL [2] Depot-Rendite: %', v_row; END IF;
  RAISE NOTICE 'PASS [2] Depot-XIRR 49,74 %% p.a. ueber den Jahreswechsel';
END $$;

ROLLBACK;
