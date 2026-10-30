-- tests/db/finance/test_fn_depot_cover_state.sql
-- finance.fn_depot_cover_state(account_id) — die EINE Regel „deckt der Marktwert eines Depots das Ziel-Geld darin?"
-- (Mini-App Ziele/Konten + Berater-Alert reserve_coverage_depot, 2026-10-30):
--   unknown = Kurs/Wechselkurs fehlt (ganzes Depot, eine Position oder ein Ziel-Anteil ohne Kurs) -> nie gruen
--   dip     = Marktwert unter der Reserve, Fehlbetrag < finance.depot_cover_warn_pct % der Reserve (Kursdelle)
--   short   = Fehlbetrag ab der Schwelle (echte Luecke)
--   ok      = gedeckt (auch ohne Reserve)
-- Erfundene Werte. Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_settle int; v_dip int; v_short int; v_noprice int; v_part int; v_fx int; v_ok int; v_g int; v_g2 int; r jsonb;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('CHF', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF' OR base_currency = 'CHF';
  IF NOT EXISTS (SELECT 1 FROM core.config WHERE category = 'finance' AND key = 'depot_cover_warn_pct' AND value = '10') THEN
    RAISE EXCEPTION 'FAIL [0] Config finance.depot_cover_warn_pct = 10 fehlt im Seed'; END IF;

  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__dcs_settle__', 'cash', 'EUR', 'active') RETURNING id INTO v_settle;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_dip__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_dip;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_short__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_short;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_noprice__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_noprice;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_part__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_part;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_fx__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_fx;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES
    ('__dcs_ok__', 'stocks_depot', 'EUR', 'active', v_settle) RETURNING id INTO v_ok;

  -- Marktwerte: dip 1000, short 880, noprice ohne Kurs, part 500 + eine Position ohne Kurs, fx 1000, ok 1000
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency) VALUES
    (v_dip, 'DCSA', 'A', 10, 90, 'EUR'), (v_short, 'DCSB', 'B', 8, 100, 'EUR'), (v_noprice, 'DCSC', 'C', 5, 100, 'EUR'),
    (v_part, 'DCSD', 'D', 5, 100, 'EUR'), (v_part, 'DCSE', 'E', 1, 100, 'EUR'), (v_fx, 'DCSF', 'F', 10, 100, 'EUR'),
    (v_ok, 'DCSG', 'G', 10, 100, 'EUR');
  INSERT INTO finance.market_prices (symbol, price, currency, as_of) VALUES
    ('DCSA', 100, 'EUR', current_date), ('DCSB', 110, 'EUR', current_date), ('DCSD', 100, 'EUR', current_date),
    ('DCSF', 100, 'EUR', current_date), ('DCSG', 100, 'EUR', current_date);

  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__dcs_goal__', 5000, current_date + 365) RETURNING id INTO v_g;
  INSERT INTO finance.savings_goals (name, target_amount, target_date) VALUES ('__dcs_goal2__', 5000, current_date + 365) RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, kind) VALUES
    (v_g, v_dip, 1004, 'manual'),       -- 4 von 1004 = 0,4 % -> dip
    (v_g, v_short, 1000, 'manual'),     -- 120 von 1000 = 12 % -> short
    (v_g, v_noprice, 100, 'manual'),
    (v_g, v_part, 100, 'manual'),
    (v_g, v_ok, 600, 'manual');
  -- Ziel-Anteil in CHF ohne Wechselkurs auf dem fx-Depot (zweites Ziel) -> Reserve nicht ermittelbar
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
    VALUES (v_g2, v_fx, 100, 'CHF', 'sparplan_buy');

  r := finance.fn_depot_cover_state(v_dip);
  IF r->>'state' <> 'dip' OR (r->>'gap')::numeric IS DISTINCT FROM 4.00 THEN RAISE EXCEPTION 'FAIL [1] Kursdelle 0,4 %% -> dip/4, got %', r; END IF;
  r := finance.fn_depot_cover_state(v_short);
  IF r->>'state' <> 'short' OR (r->>'gap')::numeric IS DISTINCT FROM 120.00 THEN RAISE EXCEPTION 'FAIL [2] 12 %% -> short/120, got %', r; END IF;
  r := finance.fn_depot_cover_state(v_noprice);
  IF r->>'state' <> 'unknown' THEN RAISE EXCEPTION 'FAIL [3] ohne Kurs -> unknown, got %', r; END IF;
  r := finance.fn_depot_cover_state(v_part);
  IF r->>'state' <> 'unknown' THEN RAISE EXCEPTION 'FAIL [4] eine Position ohne Kurs -> unknown, got %', r; END IF;
  r := finance.fn_depot_cover_state(v_fx);
  IF r->>'state' <> 'unknown' THEN RAISE EXCEPTION 'FAIL [5] Ziel-Anteil ohne Wechselkurs -> unknown, got %', r; END IF;
  r := finance.fn_depot_cover_state(v_ok);
  IF r->>'state' <> 'ok' OR (r->>'gap')::numeric IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL [6] gedeckt -> ok/0, got %', r; END IF;
  IF finance.fn_depot_cover_state(v_settle)->>'state' <> 'ok' THEN RAISE EXCEPTION 'FAIL [7] ohne Reserve -> ok'; END IF;
  -- Depot ohne Ziel-Geld mit einer Position ohne Kurs: nichts zu decken -> ok, nicht „unbekannt" (Code-Review 2026-10-30)
  DELETE FROM finance.savings_goal_reserve_entries WHERE account_id = v_noprice;
  IF finance.fn_depot_cover_state(v_noprice)->>'state' <> 'ok' THEN RAISE EXCEPTION 'FAIL [7b] ohne Ziel-Geld, Kurs fehlt -> ok'; END IF;
  RAISE NOTICE 'PASS [1-7] dip / short / unknown (kein Kurs, Teilkurs, fx-Anteil) / ok';

  -- Schwelle aus der Config: 0,3 %% -> dieselbe Delle ist eine echte Luecke
  UPDATE core.config SET value = '0.3' WHERE category = 'finance' AND key = 'depot_cover_warn_pct';
  IF finance.fn_depot_cover_state(v_dip)->>'state' <> 'short' THEN RAISE EXCEPTION 'FAIL [8] Schwelle 0,3 %% -> short'; END IF;
  RAISE NOTICE 'PASS [8] Schwelle zur Laufzeit aus core.config';
END $$;
ROLLBACK;
