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
