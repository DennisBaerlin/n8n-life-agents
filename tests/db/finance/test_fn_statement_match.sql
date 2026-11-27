-- tests/db/finance/test_fn_statement_match.sql
-- finance.fn_statement_match(account, cut, period_end, lines): Grenzen der Zuordnung, erfundene Werte, self-contained.
--   (1) Eine Zeile genau am Stichtag p_cut steckt schon im bestaetigten Saldo: weder zugeordnet noch im Rest.
--   (2) Stufe B mit Namens-Token toleriert +-5 % (mind. 2,00) um den Soll-Betrag, in BEIDE Richtungen: eine doppelt so
--       hohe Abbuchung trifft den Dauerauftrag nicht.
BEGIN;
DO $$
DECLARE
  t     DATE := CURRENT_DATE;
  v_acc INT;
  v_rp  INT;
  v_m   JSONB;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__sm_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_rp := finance.fn_add_recurring_payment(v_acc, -100, '__sm Stromabschlag Testwerk__', 1::smallint, 'month'::finance.schedule_unit,
            NULL::smallint, t - 25, t - 25, NULL, NULL, NULL);

  -- (1) Stichtag t - 30: die Zeile am Stichtag zaehlt nicht, die danach schon
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 30)::text, 'amount', -40, 'counterparty', 'Baeckerei Beispiel'),
           jsonb_build_object('date', (t - 29)::text, 'amount', -7, 'counterparty', 'Kiosk Beispiel')));
  IF (v_m->>'unmatched_out')::numeric IS DISTINCT FROM -7 OR v_m->'unmatched' IS DISTINCT FROM '[2]'::jsonb THEN
    RAISE EXCEPTION 'FAIL [1 Stichtag]: Zeile am Stichtag darf nicht zaehlen, got %', v_m; END IF;
  -- auch kein Treffer: die passende Abbuchung genau am Stichtag (Faelligkeit t - 25) gehoert zum bestaetigten Saldo
  v_m := finance.fn_statement_match(v_acc, t - 25, t, jsonb_build_array(
           jsonb_build_object('date', (t - 25)::text, 'amount', -100, 'counterparty', 'Stromabschlag Testwerk')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN
    RAISE EXCEPTION 'FAIL [1b Treffer am Stichtag]: %', v_m; END IF;
  RAISE NOTICE 'PASS [1 Zeile am Stichtag zaehlt nicht]';

  -- (2) Faelligkeit t - 25, Soll -100: -200 mit Namens-Token ist kein Treffer, -104 schon
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 25)::text, 'amount', -200, 'counterparty', 'Stromabschlag Testwerk')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN
    RAISE EXCEPTION 'FAIL [2a doppelter Betrag trifft]: %', v_m; END IF;
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 25)::text, 'amount', -104, 'counterparty', 'Stromabschlag Testwerk')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_rp OR v_m->'matched'->0->>'stage' IS DISTINCT FROM 'B' THEN
    RAISE EXCEPTION 'FAIL [2b 4 %% Abweichung mit Token trifft]: %', v_m; END IF;
  RAISE NOTICE 'PASS [2 Toleranz in beide Richtungen]';
END $$;
ROLLBACK;

-- Verspaetete Abbuchung: gleicher Betrag + Namensbezug bis 14 Tage nach Faelligkeit, nur Monats-/Jahres-Rhythmus.
BEGIN;
DO $$
DECLARE
  t date := CURRENT_DATE; v_acc int; v_rp int; v_w int; v_m jsonb;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__sm14_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_rp := finance.fn_add_recurring_payment(v_acc, -120, '__sm Versicherung Muster__', 1::smallint, 'month'::finance.schedule_unit,
            NULL::smallint, t - 25, t - 25, NULL, NULL, NULL);
  -- +14: zugeordnet, nichts im Rest
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 11)::text, 'amount', -120, 'counterparty', 'Versicherung Muster', 'purpose', 'Beitrag')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_rp OR (v_m->>'unmatched_out')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [14 Tage zugeordnet]: %', v_m; END IF;
  -- +15: nicht mehr
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 10)::text, 'amount', -120, 'counterparty', 'Versicherung Muster', 'purpose', 'Beitrag')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [15 Tage]: %', v_m; END IF;
  -- +12 ohne Namensbezug: bleibt bei 10 Tagen
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 13)::text, 'amount', -120, 'counterparty', 'Assekuranz', 'purpose', 'Beitrag')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [ohne Name]: %', v_m; END IF;
  -- +12, Betrag nur aehnlich: bleibt bei 10 Tagen
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 13)::text, 'amount', -121, 'counterparty', 'Versicherung Muster', 'purpose', 'Beitrag')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [Betrag nicht exakt]: %', v_m; END IF;
  -- 4-Wochen-Rhythmus: +12 schliesst kein altes Vorkommen
  v_w := finance.fn_add_recurring_payment(v_acc, -55, '__sm Zeitung Beispiel__', 4::smallint, 'week'::finance.schedule_unit,
            NULL::smallint, t - 25, t - 25, NULL, NULL, NULL);
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 13)::text, 'amount', -55, 'counterparty', 'Zeitung Beispiel', 'purpose', 'Abo')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [4-Wochen-Rhythmus]: %', v_m; END IF;
  -- feste Monatstage (1. und 20.): +12 schliesst kein altes Vorkommen, auch wenn der naechste Termin ausser Reichweite ist
  v_w := finance.fn_add_recurring_payment(v_acc, -70, '__sm Hausgeld Beispiel__', 1::smallint, 'month'::finance.schedule_unit,
            NULL::smallint, DATE '2026-03-01', DATE '2026-03-01', NULL, NULL, NULL);
  UPDATE finance.recurring_payments SET schedule_days_of_month = '{1,20}' WHERE id = v_w;
  v_m := finance.fn_statement_match(v_acc, DATE '2026-02-25', DATE '2026-03-31', jsonb_build_array(
           jsonb_build_object('date', '2026-03-13', 'amount', -70, 'counterparty', 'Hausgeld Beispiel', 'purpose', 'Abschlag')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [feste Monatstage]: %', v_m; END IF;
  RAISE NOTICE 'PASS [verspaetete Abbuchung: 14 Tage nur exakt + Name + Monats-Rhythmus]';
END $$;
ROLLBACK;

-- Stufe 0 (Handbuchung): eine von Hand gebuchte Einzelbuchung (fn_book_transaction: kein Dauerauftrag, keine Gruppe,
-- nicht aus einem Auszug) erklaert die Zeile mit gleichem Betrag +-5 Tage, aber nur eindeutig: die Buchung passt zu
-- genau einer offenen Zeile und die Zeile zu genau einer solchen Buchung. Sonst keine stille Zuordnung.
BEGIN;
DO $$
DECLARE
  t date := CURRENT_DATE; v_acc int; v_tx int; v_tx2 int; v_m jsonb;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__smh_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_tx := (finance.fn_book_transaction(jsonb_build_object('account_id', v_acc, 'amount', 37.40, 'direction', 'outflow',
             'description', 'Buchladen Beispiel', 'transaction_date', (t - 14)::text))->>'tx_id')::int;

  -- (H1) passende Zeile 2 Tage spaeter -> Stufe 0 booked mit der transaction_id, nichts offen
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 12)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 1 OR v_m->'matched'->0->>'stage' IS DISTINCT FROM '0'
     OR v_m->'matched'->0->>'kind' IS DISTINCT FROM 'booked'
     OR (v_m->'matched'->0->>'transaction_id')::int IS DISTINCT FROM v_tx
     OR (v_m->>'unmatched_out')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [H1 Handbuchung erklaert die Zeile]: %', v_m; END IF;

  -- (H2) Zeile 6 Tage daneben bzw. anderer Betrag -> kein Treffer
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 8)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster'),
           jsonb_build_object('date', (t - 14)::text, 'amount', -37.41, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [H2 Fenster/Betrag]: %', v_m; END IF;

  -- (H3) zwei gleiche Zeilen, eine Handbuchung -> mehrdeutig, keine Zuordnung (beide bleiben offen)
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 14)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster'),
           jsonb_build_object('date', (t - 13)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 0 OR (v_m->>'unmatched_out')::numeric IS DISTINCT FROM -74.80 THEN
    RAISE EXCEPTION 'FAIL [H3 zwei Zeilen, eine Buchung]: %', v_m; END IF;

  -- (H4) zwei gleiche Handbuchungen, eine Zeile -> mehrdeutig, keine Zuordnung
  v_tx2 := (finance.fn_book_transaction(jsonb_build_object('account_id', v_acc, 'amount', 37.40, 'direction', 'outflow',
             'description', 'Buchladen Beispiel 2', 'transaction_date', (t - 13)::text))->>'tx_id')::int;
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 13)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [H4 zwei Buchungen, eine Zeile]: %', v_m; END IF;
  DELETE FROM finance.transactions WHERE id = v_tx2;

  -- (H5) Handbuchung ohne Zeile -> kein Treffer, die andere Zeile bleibt offen
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 10)::text, 'amount', -12, 'counterparty', 'Kiosk Beispiel')));
  IF jsonb_array_length(v_m->'matched') <> 0 OR (v_m->>'unmatched_out')::numeric IS DISTINCT FROM -12 THEN
    RAISE EXCEPTION 'FAIL [H5 ohne Zeile]: %', v_m; END IF;

  -- (H6) eine Abgleichsbuchung (Rest/Drift eines Abgleichs) ist keine Handbuchung
  UPDATE finance.transactions SET category = 'reconciliation' WHERE id = v_tx;
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 14)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [H6 Abgleichsbuchung zaehlt nicht]: %', v_m; END IF;
  UPDATE finance.transactions SET category = 'other' WHERE id = v_tx;

  -- (H7) zweite Zeile gleichen Betrags gehoert per Schluessel (Stufe A) einem Dauerauftrag: sie zaehlt fuer die
  --      Eindeutigkeit nicht, die Handbuchung erklaert die erste Zeile, der Dauerauftrag die zweite
  v_tx2 := finance.fn_add_recurring_payment(v_acc, -37.40, '__smh Abo Muster__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, t - 12, t - 12, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_tx2, 'counterparty_iban', 'DE02120300000000202051', 'user');
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 14)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster'),
           jsonb_build_object('date', (t - 12)::text, 'amount', -37.40, 'counterparty', 'Verlag', 'counterparty_iban', 'DE02 1203 0000 0000 2020 51')));
  IF jsonb_array_length(v_m->'matched') <> 2
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_m->'matched') x WHERE (x->>'line_idx')::int = 1 AND (x->>'transaction_id')::int = v_tx)
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_m->'matched') x WHERE (x->>'line_idx')::int = 2 AND x->>'stage' = 'A') THEN
    RAISE EXCEPTION 'FAIL [H7 Schluessel-Zeile zaehlt nicht mit]: %', v_m; END IF;
  DELETE FROM finance.recurring_payments WHERE id = v_tx2;

  -- (H8) Handbuchung nach dem Auszugsende (noch nicht abgebucht) erklaert keine Zeile im Zeitraum
  UPDATE finance.transactions SET transaction_date = t - 8 WHERE id = v_tx;
  v_m := finance.fn_statement_match(v_acc, t - 30, t - 10, jsonb_build_array(
           jsonb_build_object('date', (t - 11)::text, 'amount', -37.40, 'counterparty', 'Buchhandlung Muster')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [H8 nach period_end]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Stufe 0 Handbuchung: eindeutig, Fenster, Mehrdeutigkeit, ohne Zeile, Schluessel-Zeile, nach Auszugsende]';
END $$;
ROLLBACK;

-- Stufe C (Einnahme ueber 150 % mit Schluessel): Gehalt und Sonderzahlung kommen in einer Ueberweisung vom bekannten Absender
-- (Gegen-IBAN der Kette) und liegen ueber 150 % des Solls. Die Zeile gehoert zum Gehalts-Vorkommen, sonst gaelte das
-- Gehalt als fehlend und die ganze Summe stuende im Rest. Untergrenze 50 % und Ausgaben (Obergrenze 150 %) bleiben.
BEGIN;
DO $$
DECLARE
  t date := CURRENT_DATE; v_acc int; v_sal int; v_exp int; v_m jsonb;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__smx_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_sal := finance.fn_add_recurring_payment(v_acc, 2400, '__smx Lohn Beispielfirma__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, t - 25, t - 25, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_sal, 'counterparty_iban', 'DE02120300000000202051', 'user');

  -- (X1) 2400 + 1800 = 4200 (175 %) mit Schluessel -> Stufe C auf das Gehalts-Vorkommen, nichts im Rest
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 4200, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02 1203 0000 0000 2020 51', 'purpose', 'Bezuege')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_sal OR v_m->'matched'->0->>'stage' IS DISTINCT FROM 'C'
     OR (v_m->'matched'->0->>'amount')::numeric IS DISTINCT FROM 4200 OR (v_m->>'unmatched_in')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [X1 Gehalt plus Sonderzahlung ueber 150 %% trifft das Gehalt]: %', v_m; END IF;

  -- (X2) ohne Schluessel (fremde IBAN) bleibt die Obergrenze: kein Treffer
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 4200, 'counterparty', 'Jemand Anderes',
                              'counterparty_iban', 'DE75512108001245126199', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [X2 ohne Schluessel]: %', v_m; END IF;

  -- (X3) Untergrenze bleibt: 1000 (42 %) vom Schluessel trifft nicht
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 1000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [X3 Untergrenze]: %', v_m; END IF;

  -- (X4) Gehalt und Sonderzahlung auf zwei Zeilen: das Gehalt nimmt die Zeile mit der kleineren Abweichung
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 5000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Praemie'),
           jsonb_build_object('date', (t - 24)::text, 'amount', 2400, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 1 OR (v_m->'matched'->0->>'line_idx')::int IS DISTINCT FROM 2
     OR (v_m->>'unmatched_in')::numeric IS DISTINCT FROM 5000 THEN
    RAISE EXCEPTION 'FAIL [X4 zwei Zeilen: Gehalt = kleinere Abweichung]: %', v_m; END IF;

  -- (X5) Ausgabe mit Mandat: doppelte Abbuchung (200 %) trifft weiter nicht
  v_exp := finance.fn_add_recurring_payment(v_acc, -60, '__smx Verein Beispiel__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, t - 20, t - 20, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_exp, 'sepa_mandate', 'DE00ZZZ00000000001|SMX-1', 'user');
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 19)::text, 'amount', -120, 'counterparty', 'Verein Beispiel',
                              'creditor_id', 'DE00ZZZ00000000001', 'mandate_ref', 'SMX-1', 'purpose', 'Beitrag')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [X5 Ausgabe behaelt Obergrenze]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Stufe C: Einnahme mit Schluessel ohne Obergrenze, Untergrenze und Ausgaben unveraendert]';

  -- (X6) zweite, kleinere Einnahme-Kette mit demselben Absender (Zuschuss): sie bekommt keine Zeile ueber 150 %, auch wenn
  --      das Gehalt ausserhalb seines Fensters liegt (frueh gezahltes Gehalt bleibt offen statt auf dem Zuschuss zu landen)
  v_exp := finance.fn_add_recurring_payment(v_acc, 40, '__smx Zuschuss Beispiel__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, t - 8, t - 8, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_exp, 'counterparty_iban', 'DE02120300000000202051', 'user');
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 8)::text, 'amount', 2400, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_m->'matched') x WHERE (x->>'recurring_payment_id')::int = v_exp) THEN
    RAISE EXCEPTION 'FAIL [X6 kleinere Kette mit gleichem Schluessel bleibt bei 150 %%]: %', v_m; END IF;
  -- die groesste Kette des Absenders behaelt den Treffer ohne Obergrenze
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 4200, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_sal THEN
    RAISE EXCEPTION 'FAIL [X6b groesste Kette behaelt den Treffer]: %', v_m; END IF;
  DELETE FROM finance.recurring_payment_keys WHERE recurring_payment_id = v_exp;

  -- (X7) von Hand gebuchte grosse Einnahme vom selben Absender (Abfindung): die Handbuchung erklaert ihre Zeile weiter,
  --      das Gehalt nimmt die passende Zeile
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id', v_acc, 'amount', 9000, 'direction', 'inflow',
             'description', 'Abfindung Beispiel', 'transaction_date', (t - 24)::text));
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 2400, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege'),
           jsonb_build_object('date', (t - 24)::text, 'amount', 9000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Abfindung')));
  IF jsonb_array_length(v_m->'matched') <> 2 OR (v_m->>'unmatched_in')::numeric IS DISTINCT FROM 0
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_m->'matched') x WHERE (x->>'line_idx')::int = 2 AND x->>'kind' = 'booked')
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_m->'matched') x WHERE (x->>'line_idx')::int = 1
                    AND (x->>'recurring_payment_id')::int = v_sal) THEN
    RAISE EXCEPTION 'FAIL [X7 Handbuchung ueber 150 %% bleibt erkannt]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Stufe C: nur groesste Einnahme-Kette des Schluessels, Handbuchung gewinnt]';

  -- (X8) groessere Einnahme-Kette mit derselben IBAN auf einem anderen Konto (zwei Renten derselben Kasse) sperrt nicht
  v_exp := (finance.fn_create_account('{"name":"__smx_giro_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_exp := finance.fn_add_recurring_payment(v_exp, 3000, '__smx Lohn Partner__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, t - 25, t - 25, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_exp, 'counterparty_iban', 'DE02120300000000202051', 'user');
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 4200, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_sal THEN
    RAISE EXCEPTION 'FAIL [X8 Kette auf anderem Konto sperrt nicht]: %', v_m; END IF;

  -- (X9) jaehrliche Sonderzahlungs-Kette mit hoeherem Einzelbetrag, aber kleinerem Monatswert: das Gehalt behaelt den
  --      Treffer ueber 150 % (sonst ginge das Gehalt des Monats verloren)
  v_exp := finance.fn_add_recurring_payment(v_acc, 3000, '__smx Weihnachtsgeld Beispiel__', 1::smallint, 'year'::finance.schedule_unit,
             NULL::smallint, t - 23, t - 23, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_exp, 'counterparty_iban', 'DE02120300000000202051', 'user');
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 7000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF (v_m->'matched'->0->>'recurring_payment_id')::int IS DISTINCT FROM v_sal THEN
    RAISE EXCEPTION 'FAIL [X9 Jahres-Kette nimmt das Gehalt nicht]: %', v_m; END IF;
  DELETE FROM finance.recurring_payment_keys WHERE recurring_payment_id = v_exp;
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_exp;

  -- (X10) exakter Treffer ohne IBAN (Stufe B) geht vor: die Praemien-Zeile mit IBAN nimmt dem Gehalt die Zeile nicht
  v_m := finance.fn_statement_match(v_acc, t - 30, t, jsonb_build_array(
           jsonb_build_object('date', (t - 24)::text, 'amount', 5000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Praemie'),
           jsonb_build_object('date', (t - 24)::text, 'amount', 2400, 'counterparty', 'Arbeitgeber Muster', 'purpose', 'Lohn')));
  IF jsonb_array_length(v_m->'matched') <> 1 OR (v_m->'matched'->0->>'line_idx')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL [X10 Stufe B vor Stufe C]: %', v_m; END IF;

  -- (X11) Vorkommen nach dem Auszugsende bekommt keine Zeile ueber 150 % (das Gehalt kommt erst im naechsten Auszug)
  v_m := finance.fn_statement_match(v_acc, t - 60, t - 27, jsonb_build_array(
           jsonb_build_object('date', (t - 29)::text, 'amount', 5000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Erstattung')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [X11 Faelligkeit nach period_end]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Stufe C: Monatswert, nur eigenes Konto, nach Stufe B, bis period_end]';
END $$;
ROLLBACK;

-- Stufe C nach einer Gehaltserhoehung: der gelernte Schluessel bleibt am alten Glied, die groessere Kette zaehlt trotzdem
-- (sonst naehme der kleine Zuschuss mit derselben IBAN ein frueh gezahltes Gehalt). Mandat ohne IBAN: keine Stufe C.
BEGIN;
DO $$
DECLARE
  v_acc int; v_sal int; v_new int; v_all int; v_m jsonb;
BEGIN
  v_acc := (finance.fn_create_account('{"name":"__smy_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_sal := finance.fn_add_recurring_payment(v_acc, 2400, '__smy Lohn Beispielfirma__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, DATE '2026-03-01', DATE '2026-03-01', NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_sal, 'counterparty_iban', 'DE02120300000000202051', 'user');
  v_new := (finance.fn_split_recurring_payment(v_sal, DATE '2026-04-15', 2600, NULL, NULL, NULL, NULL, NULL, NULL)
            ->>'recurring_payment_id')::int;
  IF v_new IS NULL OR v_new = v_sal THEN RAISE EXCEPTION 'SETUP split: %', v_new; END IF;
  v_all := finance.fn_add_recurring_payment(v_acc, 40, '__smy Zuschuss Beispiel__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, DATE '2026-05-15', DATE '2026-05-15', NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_all, 'counterparty_iban', 'DE02120300000000202051', 'user');

  -- (Y1) 2600 am Zuschuss-Termin, Gehalt 14 Tage entfernt: kein Treffer
  v_m := finance.fn_statement_match(v_acc, DATE '2026-04-30', DATE '2026-05-31', jsonb_build_array(
           jsonb_build_object('date', '2026-05-15', 'amount', 2600, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE02120300000000202051', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN
    RAISE EXCEPTION 'FAIL [Y1 Split-Kette mit Schluessel am alten Glied sperrt den Zuschuss]: %', v_m; END IF;

  -- (Y2) Einnahme ueber 150 % nur mit Mandat (keine Gegen-IBAN): keine Stufe C
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_new, 'sepa_mandate', 'DE00ZZZ00000000002|SMY-1', 'user');
  v_m := finance.fn_statement_match(v_acc, DATE '2026-04-30', DATE '2026-05-31', jsonb_build_array(
           jsonb_build_object('date', '2026-05-01', 'amount', 9000, 'counterparty', 'Arbeitgeber Muster',
                              'creditor_id', 'DE00ZZZ00000000002', 'mandate_ref', 'SMY-1', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [Y2 Mandat ohne IBAN]: %', v_m; END IF;

  -- (Y3) Einnahme-Kette nur mit Mandat, Zeile mit Mandat und unbekannter IBAN ueber 150 %: keine Stufe C (Stufe C nur ueber die Gegen-IBAN)
  v_all := finance.fn_add_recurring_payment(v_acc, 30, '__smy Bonus Beispiel__', 1::smallint, 'month'::finance.schedule_unit,
             NULL::smallint, DATE '2026-05-20', DATE '2026-05-20', NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_all, 'sepa_mandate', 'DE00ZZZ00000000006|SMY-2', 'user');
  v_m := finance.fn_statement_match(v_acc, DATE '2026-04-30', DATE '2026-05-31', jsonb_build_array(
           jsonb_build_object('date', '2026-05-20', 'amount', 9000, 'counterparty', 'Arbeitgeber Muster',
                              'counterparty_iban', 'DE75512108001245126199', 'creditor_id', 'DE00ZZZ00000000006',
                              'mandate_ref', 'SMY-2', 'purpose', 'Bezuege')));
  IF jsonb_array_length(v_m->'matched') <> 0 THEN RAISE EXCEPTION 'FAIL [Y3 Mandat-Treffer ist kein Stufe-C-Schluessel]: %', v_m; END IF;
  RAISE NOTICE 'PASS [Stufe C: Split-Kette zaehlt ueber ihr aktives Glied, nur mit Gegen-IBAN]';
END $$;
ROLLBACK;
