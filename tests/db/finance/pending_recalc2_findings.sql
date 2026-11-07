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

-- (F2) Anzeige: Puffer-Hinweis knapp unter der Grenze nennt den Zielwert als Ist-Wert (Text widerspricht sich).
--      fn_advisor_review rundet den Anteil "frei / Einnahmen" kaufmaennisch auf eine Stelle: Einnahmen 3.000, frei 299,99
--      -> 9,9997 % -> "nur 299,99 EUR frei (10,0 % der Einnahmen, Ziel 10 %)". Der Hinweis feuert zu Recht (299,99 < 300),
--      der Satz liest sich aber wie "Ziel erreicht". Betroffen: frei zwischen 9,95 % und 10 % der Einnahmen.
--      Erwartung: unter dem Ziel nie >= Ziel anzeigen -> abrunden auf eine Stelle: 9,9.
--      Fix-Vorschlag: 'pct' = trunc(v_free / income * 100, 1) im Zweig cashflow_buffer (Zeile mit fn_ui_num(... , 1)).
--      Nebenbefund gleiche Stelle: 'target' wird ohne Nachkommastelle gezeigt (Config 0,125 -> "Ziel 13 %").
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.account_balances SET balance = 0;
DO $$
DECLARE
  v_giro int; r jsonb; a jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f2_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from) VALUES
    ('__r2f2_gehalt__', v_giro, 3000, 'month', current_date, current_date),
    ('__r2f2_miete__', v_giro, -2700.01, 'month', current_date, current_date);
  r := finance.fn_advisor_review('finance');
  SELECT x INTO a FROM jsonb_array_elements(r->'alerts') x WHERE x->>'kind' = 'cashflow_coverage';
  IF (a->'msg'->0->'params'->'pct'->>'value')::numeric IS DISTINCT FROM 9.9 THEN
    RAISE EXCEPTION 'FAIL [F2] Puffer-Anteil unter dem Ziel: erwartet 9.9 (abgerundet), got % (Ziel %)',
      a->'msg'->0->'params'->'pct'->>'value', a->'msg'->0->'params'->'target'->>'value'; END IF;
END $$;
ROLLBACK;

-- (F3) Sondertilgung ohne ausdruecklichen Tilgungsanteil verliert einen vollen Periodenzins (Fachregel-Abweichung).
--      Fachregel: eine Sondertilgung mindert die Restschuld in voller Hoehe; Zins faellt periodisch auf die Restschuld
--      an und ist mit der regulaeren Rate der Periode bezahlt (https://de.wikipedia.org/wiki/Sondertilgung).
--      fn_get_loan_payment_split rechnet fuer JEDE Zahlung ohne principal_amount Zins = Rest x Satz / 12 x Monate der
--      Rate. Den Tilgungsanteil muss heute das Modell mitgeben (Tool-Description "Set only for Sondertilgung") - das ist
--      Komfort-Ebene, die DB setzt es nicht durch.
--      Beispiel: 100.000 zu 3 %, regulaere Rate 800 heute gebucht (Zins 250, Tilgung 550 -> Rest 99.450),
--        danach 5.000 Sondertilgung ohne principal_amount:
--        Erwartung: Zins 0, Tilgung 5.000 (Zins der Periode ist mit der Rate bezahlt).
--        DB: Zins 99.450 x 0,25 % = 248,63, Tilgung 4.751,37 (248,63 EUR doppelt als Zins verbucht).
--      Fix-Vorschlag: in fn_get_loan_payment_split eine Zahlung, die keinem offenen Vorkommen zugeordnet wird, waehrend
--      die Rate der laufenden Periode schon gebucht ist, als reine Tilgung behandeln (Zins 0); oder ein ausdrueckliches
--      Feld kind = 'extra' mit Zins 0 in der fn statt der Tool-Description. Auslegung offen, wenn KEINE Rate in der
--      Periode gebucht ist (dann waere der aufgelaufene Tageszins seit der letzten Rate fachlich korrekt).
BEGIN;
UPDATE finance.recurring_payments SET status = 'paused';
DO $$
DECLARE
  v_giro int; v_la int; v_rp int; v_l int; r jsonb;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f3_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2f3_loan__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2f3_rate__', v_giro, -800, 'month', current_date - 2, current_date - 2) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__r2f3_kredit__', 3.0, 'active', v_la, v_giro, v_rp) RETURNING id INTO v_l;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id) VALUES (v_la, -100000, current_date - 40, 'disbursement', v_l);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, 20000, current_date - 40, 'other');
  r := finance.fn_book_loan_payment(jsonb_build_object('loan_id', v_l, 'loan_account_id', v_la, 'debit_account_id', v_giro,
                                                      'payment_amount', 800, 'payment_date', current_date::text));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'remaining_debt')::numeric IS DISTINCT FROM 99450.00 OR r->>'matched_due_date' IS NULL THEN
    RAISE EXCEPTION 'SETUP [F3] regulaere Rate: %', r; END IF;
  r := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l, 'payment_amount', 5000, 'payment_date', current_date::text));
  IF (r->>'principal_amount')::numeric IS DISTINCT FROM 5000.00 OR (r->>'interest_portion')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [F3] Sondertilgung nach gebuchter Rate: erwartet Tilgung 5000 / Zins 0, got Tilgung % / Zins %',
      r->>'principal_amount', r->>'interest_portion'; END IF;
END $$;
ROLLBACK;
