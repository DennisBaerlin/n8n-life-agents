-- tests/db/finance/pending_recalc2_findings.sql
-- PENDING: Abweichungen der Zweitrechnung Runde 2 (finance), bewusst ROT und ausserhalb des Gates (db_test sammelt nur
-- test_*.sql). Lauf von Hand: .\scripts\db_test.ps1 -Filter 'pending_recalc2_*'
-- Jeder Fall nennt die unabhaengige Erwartung; die fn bleibt unveraendert (fn-Dateien gehoerten in dieser Nacht der
-- Mutations-Session), bis der Owner entschieden bzw. jemand den Fix gebaut hat. Nach dem Fix den Fall in die passende
-- test_recalc2_*.sql verschieben (dann gruen und im Gate).
--   (F1) Depot-Zeile der Vermoegen-Seite rundet je Anlageklasse, das Aufklappen je Depot (Cent-Abweichung, Sichten-Konsistenz):
--        networth_by_asset_class rundet sum(value_eur) je (bucket, asset_class, owner) auf Cent; fn_app_screen_overview
--        summiert diese gerundeten Gruppen zur Zeile "Wertpapiere" und zum Hero, das Aufklappen rundet dagegen je Depot
--        (networth_items). Ein Depot mit zwei Klassen: Welt 3 x 10,005 = 30,015, Anleihen 1 x 20,005 = 20,005.
--          Erwartung (einmal gerundet): 50,020 -> 50,02 = Summe des Aufklappens.
--          DB-Zeile: round(30,015) + round(20,005) = 30,02 + 20,01 = 50,03 (1 Cent mehr als die Teile; Hero ebenso).
--        Fehler bis 0,005 je Anlageklasse und Person. Gleiche Fehlerklasse wie Runde 1 P1 (doppelte Rundung).
--        Fix-Vorschlag: fn_app_screen_overview (und Depot-Hero) summieren networth_items unrund und runden einmal am
--        Ende; oder networth_by_asset_class gibt zusaetzlich value_eur_exact aus. Die View-Ausgabe selbst (Advisor) bleibt.
BEGIN;

DO $$
DECLARE
  v_dep int; v_giro int; v jsonb; v_row numeric; v_det numeric;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('r2f1', 'Owner Muster', 'owner');
  UPDATE finance.accounts SET status = 'closed' WHERE status = 'active';
  UPDATE finance.real_estate SET status = 'sold' WHERE status = 'active';
  UPDATE finance.pension SET current_value = NULL;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f1_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id) VALUES ('__r2f1_dep__', 'stocks_depot', 'EUR', 'active', v_giro) RETURNING id INTO v_dep;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name, shares, average_purchase_price, currency, asset_class) VALUES
    (v_dep, 'R2F00000001', 'R2FW', 'Welt', 3, 10.005, 'EUR', 'world'),
    (v_dep, 'R2F00000002', 'R2FB', 'Anleihen', 1, 20.005, 'EUR', 'bonds');
  v := finance.fn_app_screen_overview('{"person_id":"r2f1","params":{}}');
  SELECT (i->'value'->>'value')::numeric, (SELECT sum((d->'value'->>'value')::numeric) FROM jsonb_array_elements(i->'details') d)
    INTO v_row, v_det
    FROM jsonb_array_elements(v->'sections') s, jsonb_array_elements(s->'items') i
   WHERE i->'label'->>'value' = 'depot';
  IF v_row IS DISTINCT FROM 50.02 OR v_det IS DISTINCT FROM 50.02 THEN
    RAISE EXCEPTION 'FAIL [F1] Depot-Zeile: erwartet 50.02 = Aufklappen, got Zeile % / Aufklappen %', v_row, v_det; END IF;
END $$;

ROLLBACK;
