-- tests/db/finance/test_fn_record_networth_snapshot.sql
-- Tagesstand des Vermoegens (finance.networth_snapshots + fn_record_networth_snapshot):
--   Stand = networth_items je Objekt zum Aufrufzeitpunkt, Tag = core.fn_today(); die Summe je (bucket, Klasse, Person)
--   ergibt exakt networth_by_asset_class. Ein zweiter Lauf am selben Tag ersetzt den Tagesstand (auch weggefallene
--   Zeilen), fruehere Tage bleiben unberuehrt, Kredite zaehlen negativ mit.
--   Gesetz: UNIQUE (Tag, Objekt, bucket, Klasse) mit NULLS NOT DISTINCT, bucket-/item_kind-CHECK, Wert NULL nur mit
--   FX-Luecke, Person geloescht -> ihr Anteil wandert in den Haushalt (SET NULL). Objekte ohne Wert und ohne Luecke
--   fallen weg statt den Lauf abzubrechen; das E2E-Aufraeumen nimmt Tagesstaende der Testkonten mit.
--   Rolle finance_rw darf schreiben (der Cron laeuft so).
BEGIN;

DO $$
DECLARE
  v_today date := core.fn_today();
  v_cash  int;
  v_loan  int;
  v_r     jsonb;
  v_n     int;
  v_sum   numeric;
  v_val   numeric;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__nws_kid__', 'Kind Beispiel', 'child');

  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nws_cash__', 'cash', 'EUR', 'active') RETURNING id INTO v_cash;
  UPDATE finance.account_balances SET balance = 1234.56 WHERE account_id = v_cash;
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
  VALUES ('__nws_loan__', 'loan', 'EUR', 'active', '__nws_kid__') RETURNING id INTO v_loan;
  UPDATE finance.account_balances SET balance = -800 WHERE account_id = v_loan;

  -- Vortag: von Hand gesetzter Stand bleibt unberuehrt (kein Nachholen, kein Ueberschreiben).
  INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, owner_person_id, value_eur, has_fx_gap)
  VALUES (v_today - 1, 'account', v_cash, 'cash', 'cash', NULL, 42.00, false);

  -- ---------- erster Lauf ----------
  v_r := finance.fn_record_networth_snapshot();
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [ok]: %', v_r;
  END IF;
  IF (v_r->>'snapshot_date')::date IS DISTINCT FROM v_today THEN
    RAISE EXCEPTION 'FAIL [snapshot_date]: erwartet %, bekam %', v_today, v_r->>'snapshot_date';
  END IF;

  -- Summe je Anlageart = View, beidseitig (keine Zeile zu viel, keine zu wenig, kein Cent Rundungs-Drift).
  SELECT count(*) INTO v_n FROM (
    (SELECT owner_person_id, bucket, asset_class, value_eur, has_fx_gap FROM finance.networth_by_asset_class
     WHERE value_eur IS NOT NULL OR has_fx_gap
     EXCEPT
     SELECT owner_person_id, bucket, asset_class, round(sum(value_eur), 2), bool_or(has_fx_gap)
     FROM finance.networth_snapshots WHERE snapshot_date = v_today GROUP BY owner_person_id, bucket, asset_class)
    UNION ALL
    (SELECT owner_person_id, bucket, asset_class, round(sum(value_eur), 2), bool_or(has_fx_gap)
     FROM finance.networth_snapshots WHERE snapshot_date = v_today GROUP BY owner_person_id, bucket, asset_class
     EXCEPT
     SELECT owner_person_id, bucket, asset_class, value_eur, has_fx_gap FROM finance.networth_by_asset_class
     WHERE value_eur IS NOT NULL OR has_fx_gap)
  ) d;
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'FAIL [Tagesstand = View]: % abweichende Zeilen', v_n;
  END IF;

  SELECT COALESCE(sum(value_eur), 0) INTO v_sum FROM finance.networth_by_asset_class;
  IF (v_r->>'net_worth_eur')::numeric IS DISTINCT FROM v_sum THEN
    RAISE EXCEPTION 'FAIL [net_worth_eur]: erwartet %, bekam %', v_sum, v_r->>'net_worth_eur';
  END IF;
  IF (v_r->>'has_fx_gap')::boolean IS DISTINCT FROM
     (SELECT COALESCE(bool_or(has_fx_gap), false) FROM finance.networth_by_asset_class) THEN
    RAISE EXCEPTION 'FAIL [has_fx_gap]: %', v_r;
  END IF;

  -- Kredit des Kindes: eine Zeile je Objekt, negativ, bei der Person.
  SELECT value_eur INTO v_val FROM finance.networth_snapshots
  WHERE snapshot_date = v_today AND item_kind = 'account' AND item_id = v_loan
    AND owner_person_id = '__nws_kid__' AND bucket = 'loan';
  IF v_val IS DISTINCT FROM -800.00 THEN
    RAISE EXCEPTION 'FAIL [Kredit negativ bei Person]: %', v_val;
  END IF;

  -- ---------- zweiter Lauf am selben Tag: ersetzt ----------
  UPDATE finance.account_balances SET balance = 2000 WHERE account_id = v_cash;
  UPDATE finance.accounts SET status = 'closed' WHERE id = v_loan;
  v_r := finance.fn_record_networth_snapshot();

  IF EXISTS (SELECT 1 FROM finance.networth_snapshots WHERE snapshot_date = v_today AND item_id = v_loan
               AND item_kind = 'account') THEN
    RAISE EXCEPTION 'FAIL [ersetzen]: weggefallene Kredit-Zeile steht noch im Tagesstand';
  END IF;
  SELECT value_eur INTO v_val FROM finance.networth_snapshots
  WHERE snapshot_date = v_today AND item_kind = 'account' AND item_id = v_cash;
  IF v_val IS DISTINCT FROM 2000.00 THEN
    RAISE EXCEPTION 'FAIL [ersetzen]: Cash-Wert nicht aktualisiert (%)', v_val;
  END IF;
  SELECT COALESCE(sum(value_eur), 0) INTO v_sum FROM finance.networth_by_asset_class;
  IF (v_r->>'net_worth_eur')::numeric IS DISTINCT FROM v_sum THEN
    RAISE EXCEPTION 'FAIL [net_worth_eur 2]: erwartet %, bekam %', v_sum, v_r->>'net_worth_eur';
  END IF;

  SELECT value_eur INTO v_val FROM finance.networth_snapshots
  WHERE snapshot_date = v_today - 1 AND item_id = v_cash;
  IF v_val IS DISTINCT FROM 42.00 THEN
    RAISE EXCEPTION 'FAIL [Vortag unberuehrt]: %', v_val;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.networth_snapshots WHERE snapshot_date NOT IN (v_today, v_today - 1)) THEN
    RAISE EXCEPTION 'FAIL [kein Nachholen]: Zeile fuer einen anderen Tag geschrieben';
  END IF;
  RAISE NOTICE 'PASS fn_record_networth_snapshot [Tagesstand, ersetzen, Vortag, Kredit]';
END $$;

-- ---------- Depot: mehrere Positionen einer Klasse in einem Depot = eine Zeile ----------
DO $$
DECLARE
  v_today date := core.fn_today();
  v_set   int;
  v_dep   int;
  v_n     int;
  v_val   numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nws_set__', 'cash', 'EUR', 'active') RETURNING id INTO v_set;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__nws_dep__', 'stocks_depot', 'EUR', 'active', v_set) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_dep, '__NWSA__', 'Fonds A', 10, 10.005, 'EUR', 'equity'),
         (v_dep, '__NWSB__', 'Fonds B', 3, 20.005, 'EUR', 'equity');
  PERFORM finance.fn_record_networth_snapshot();
  SELECT count(*), sum(value_eur) INTO v_n, v_val FROM finance.networth_snapshots
  WHERE snapshot_date = v_today AND item_kind = 'account' AND item_id = v_dep;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'FAIL [Depot eine Zeile je Klasse]: % Zeilen', v_n;
  END IF;
  IF v_val IS DISTINCT FROM (SELECT sum(value_eur) FROM finance.networth_items
                             WHERE item_kind = 'account' AND item_id = v_dep) THEN
    RAISE EXCEPTION 'FAIL [Depot-Wert]: %', v_val;
  END IF;
  RAISE NOTICE 'PASS fn_record_networth_snapshot [Depot]';
END $$;

-- ---------- Objekte ohne Wert und ohne Luecke brechen den Lauf nicht ab ----------
-- Fremdwaehrungs-Konto mit Saldo 0 ohne Kurs (value_native 0) und Position ohne Kurs und ohne Einstand (value_native
-- NULL): beide value_eur NULL ohne has_fx_gap -> weggelassen; eine echte Luecke (Saldo <> 0 ohne Kurs) bleibt mit NULL.
DO $$
DECLARE
  v_today date := core.fn_today();
  v_zero  int;
  v_gap   int;
  v_set   int;
  v_dep   int;
  v_r     jsonb;
  v_n     int;
BEGIN
  INSERT INTO finance.currencies (code, minor_unit) VALUES ('XNW', 2) ON CONFLICT (code) DO NOTHING;
  DELETE FROM finance.fx_rates WHERE quote_currency = 'XNW';
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nws_x0__', 'cash', 'XNW', 'active') RETURNING id INTO v_zero;
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nws_xg__', 'cash', 'XNW', 'active') RETURNING id INTO v_gap;
  UPDATE finance.account_balances SET balance = 50 WHERE account_id = v_gap;
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__nws_set2__', 'cash', 'EUR', 'active') RETURNING id INTO v_set;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
  VALUES ('__nws_dep2__', 'stocks_depot', 'EUR', 'active', v_set) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, symbol, name, shares, average_purchase_price, currency, asset_class)
  VALUES (v_dep, '__NWSN__', 'Ohne Einstand', 5, NULL, 'EUR', 'bond');

  v_r := finance.fn_record_networth_snapshot();
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'has_fx_gap')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [ohne Wert]: %', v_r;
  END IF;
  SELECT count(*) INTO v_n FROM finance.networth_snapshots
  WHERE snapshot_date = v_today AND item_kind = 'account' AND item_id IN (v_zero, v_dep);
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'FAIL [ohne Wert]: % Zeilen ohne Wert und ohne Luecke geschrieben', v_n;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.networth_snapshots WHERE snapshot_date = v_today AND item_kind = 'account'
                   AND item_id = v_gap AND value_eur IS NULL AND has_fx_gap) THEN
    RAISE EXCEPTION 'FAIL [echte Luecke]: Konto ohne Kurs nicht mit NULL + has_fx_gap festgehalten';
  END IF;
  RAISE NOTICE 'PASS fn_record_networth_snapshot [ohne Wert, echte Luecke]';
END $$;

-- ---------- E2E-Aufraeumen nimmt den Tagesstand der Testkonten mit ----------
DO $$
DECLARE
  v_acc int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status)
  VALUES ('__E2E__nws_konto', 'cash', 'EUR', 'active') RETURNING id INTO v_acc;
  UPDATE finance.account_balances SET balance = 10 WHERE account_id = v_acc;
  PERFORM finance.fn_record_networth_snapshot();
  IF NOT EXISTS (SELECT 1 FROM finance.networth_snapshots WHERE item_kind = 'account' AND item_id = v_acc) THEN
    RAISE EXCEPTION 'FAIL [E2E Vorbedingung]: Testkonto nicht im Tagesstand';
  END IF;
  PERFORM finance.fn_clear_e2e_data();
  IF EXISTS (SELECT 1 FROM finance.networth_snapshots WHERE item_kind = 'account' AND item_id = v_acc) THEN
    RAISE EXCEPTION 'FAIL [E2E]: Tagesstand eines geloeschten Testkontos bleibt stehen';
  END IF;
  RAISE NOTICE 'PASS fn_clear_e2e_data -> networth_snapshots';
END $$;

-- ---------- Gesetz der Tabelle ----------
DO $$
DECLARE
  v_today date := core.fn_today();
BEGIN
  INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
  VALUES (v_today - 10, 'account', -1, 'depot', NULL, 1, false);
  BEGIN
    INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
    VALUES (v_today - 10, 'account', -1, 'depot', NULL, 2, false);
    RAISE EXCEPTION 'FAIL [UNIQUE NULLS NOT DISTINCT]: doppelte Depot-Zeile ohne Klasse angenommen';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
    VALUES (v_today - 10, 'account', -2, 'gold', 'gold', 1, false);
    RAISE EXCEPTION 'FAIL [bucket CHECK]: unbekannter bucket angenommen';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
    VALUES (v_today - 10, 'car', -2, 'cash', 'cash', 1, false);
    RAISE EXCEPTION 'FAIL [item_kind CHECK]: unbekannte Objekt-Art angenommen';
  EXCEPTION WHEN check_violation THEN NULL;
  END;

  BEGIN
    INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
    VALUES (v_today - 10, 'account', -3, 'cash', 'cash', NULL, false);
    RAISE EXCEPTION 'FAIL [Wert-CHECK]: Wert NULL ohne FX-Luecke angenommen';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, value_eur, has_fx_gap)
  VALUES (v_today - 10, 'account', -3, 'cash', 'cash', NULL, true);

  -- Person entfernt -> ihr Anteil wandert in den Haushalt, der Wert des Tages bleibt.
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('__nws_gone__', 'Weg Beispiel', 'partner');
  INSERT INTO finance.networth_snapshots (snapshot_date, item_kind, item_id, bucket, asset_class, owner_person_id, value_eur, has_fx_gap)
  VALUES (v_today - 10, 'account', -4, 'cash', 'cash', '__nws_gone__', 5, false);
  DELETE FROM agent.persons WHERE person_id = '__nws_gone__';
  IF NOT EXISTS (SELECT 1 FROM finance.networth_snapshots
                 WHERE snapshot_date = v_today - 10 AND item_id = -4 AND owner_person_id IS NULL AND value_eur = 5) THEN
    RAISE EXCEPTION 'FAIL [SET NULL]: Anteil einer entfernten Person nicht im Haushalt erhalten';
  END IF;
  RAISE NOTICE 'PASS networth_snapshots [UNIQUE, CHECKs, SET NULL]';
END $$;

-- ---------- Rolle des Crons ----------
DO $$
DECLARE
  v_r jsonb;
BEGIN
  SET LOCAL ROLE finance_rw;
  v_r := finance.fn_record_networth_snapshot();
  RESET ROLE;
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [finance_rw]: %', v_r;
  END IF;
  RAISE NOTICE 'PASS finance_rw -> fn_record_networth_snapshot';
EXCEPTION WHEN OTHERS THEN
  RESET ROLE;
  RAISE;
END $$;

ROLLBACK;
