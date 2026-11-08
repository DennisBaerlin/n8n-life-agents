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
