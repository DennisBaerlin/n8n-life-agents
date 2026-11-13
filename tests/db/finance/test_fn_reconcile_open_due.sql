-- tests/db/finance/test_fn_reconcile_open_due.sql
-- fn_reconcile_open_due: offene Vorkommen eines Kontos mit Faelligkeit <= Stichtag-10 (Quelle oder Transfer-Ziel);
-- juengere bleiben offen (10 Tage Karenz); fremde Konten zaehlen nicht. fn_reconcile_account skippt genau diese Menge.
BEGIN;

DO $$
DECLARE v_a INT; v_b INT; v_rp INT; v_n INT; v_res JSONB;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_rod_a__","account_type":"cash","currency":"EUR","opening_balance":100}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__t_rod_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name','__t_rod_abo__','direction','expense','amount',10,
            'account_id', v_a, 'schedule_unit','month','first_payment_date', to_char(CURRENT_DATE - 40,'YYYY-MM-DD')))->>'recurring_payment_id')::int;
  UPDATE finance.recurring_payments SET valid_from = CURRENT_DATE - 40 WHERE id = v_rp;   -- vor die Konto-Eroeffnung

  SELECT count(*) INTO v_n FROM finance.fn_reconcile_open_due(v_a, CURRENT_DATE) WHERE recurring_payment_id = v_rp;
  IF v_n < 1 THEN RAISE EXCEPTION 'FAIL faelliges Vorkommen fehlt'; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_reconcile_open_due(v_b, CURRENT_DATE)) THEN
    RAISE EXCEPTION 'FAIL fremdes Konto zaehlt mit'; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_reconcile_open_due(v_a, CURRENT_DATE - 45)) THEN
    RAISE EXCEPTION 'FAIL Stichtag vor der Faelligkeit darf nichts liefern'; END IF;

  -- Sammel-Vorschau (Monats-Reminder-Karte) zeigt dieselbe Anzahl je Konto
  v_res := finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
             jsonb_build_object('account_name','__t_rod_a__','confirmed_balance',100),
             jsonb_build_object('account_name','__t_rod_b__','confirmed_balance',0))));
  IF (v_res->'rows'->0->>'skip_count')::int IS DISTINCT FROM v_n OR (v_res->'rows'->1->>'skip_count')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL Sammel-Vorschau skip_count: % / %', v_n, v_res; END IF;
  -- die Karte nennt ein Datum statt "10 Tage vor" -> skip_until = spaeteste Faelligkeit
  -- der Menge, die der Abgleich als erledigt markiert (dieselbe fn); ohne offene Termine null
  IF (v_res->'rows'->0->>'skip_until') IS DISTINCT FROM
       (SELECT max(COALESCE(o.due_date, o.interest_period_end))::text FROM finance.fn_reconcile_open_due(v_a, CURRENT_DATE) o)
     OR (v_res->'rows'->0->>'skip_until') IS NULL OR (v_res->'rows'->1->>'skip_until') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL Sammel-Vorschau skip_until: %', v_res; END IF;

  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 100));
  IF (v_res->>'skipped_occurrences')::int IS DISTINCT FROM v_n
     OR EXISTS (SELECT 1 FROM finance.fn_reconcile_open_due(v_a, CURRENT_DATE)) THEN
    RAISE EXCEPTION 'FAIL Abgleich skippt nicht genau die Menge: % / %', v_n, v_res; END IF;
  RAISE NOTICE 'PASS fn_reconcile_open_due';
END $$;

-- Zins-Vorkommen haben dieselbe Karenz: value_date 2026-02-01 liegt bei Stichtag 2026-02-11 genau 10 Tage zurueck
-- (erledigt), bei Stichtag 2026-02-05 noch nicht.
DO $$
DECLARE v_a INT;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_rod_int__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, day_count_convention, valid_from)
  VALUES (v_a, 4, 1, 'month', 'ACT/365', '2026-01-01');
  IF NOT EXISTS (SELECT 1 FROM finance.fn_reconcile_open_due(v_a, DATE '2026-02-11') WHERE interest_period_end = '2026-02-01') THEN
    RAISE EXCEPTION 'FAIL Zins-Vorkommen 10 Tage alt fehlt'; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_reconcile_open_due(v_a, DATE '2026-02-05') WHERE interest_period_end = '2026-02-01') THEN
    RAISE EXCEPTION 'FAIL Zins-Vorkommen juenger als 10 Tage wird schon als erledigt markiert'; END IF;
  RAISE NOTICE 'PASS fn_reconcile_open_due [Zins-Karenz 10 Tage]';
END $$;

ROLLBACK;
