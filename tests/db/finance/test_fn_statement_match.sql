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
