-- tests/db/finance/test_v_active_insurances.sql
-- finance.active_insurances: eine laufende Police gehoert in die View, auch wenn ihr gespeicherter
-- Beginn in der Zukunft liegt. Ohne genannten Vertragsbeginn faellt valid_from auf die erste Abbuchung zurueck, und das ist
-- beim Erfassen meist die naechste Abbuchung; die Police fehlte dann in allen Lesern (Onboarding: "fehlen noch"). Werte erfunden.
--   (1) erste Abbuchung in der Zukunft -> sichtbar, Beitrag + Konto gefuellt (Kopf der Kette, noch kein gueltiges Glied)
--   (2) Dubletten-Hinweis beim Anlegen sieht diese Police (gleiche Gesellschaft, gleicher Jahresbeitrag)
--   (3) Beginn in der Vergangenheit -> sichtbar
--   (4) Status nicht aktiv -> nicht sichtbar
--   (5) Vertrag beendet (Kopf valid_to erreicht) -> nicht sichtbar; Ende in der Zukunft -> sichtbar
BEGIN;
DO $$
DECLARE
  v_acct INT; v_res JSONB; v_id INT; v_past INT; v_off INT; v_ended INT; v_rp INT; r RECORD;
  v_next DATE := current_date + 40;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__vai_acct__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;

  -- (1)
  v_res := finance.fn_create_insurance(jsonb_build_object('name', '__vai kommend__', 'insurance_company', '__vai AG__',
             'premium_amount', '120', 'schedule_unit', 'year', 'debit_account_id', v_acct, 'first_payment_date', v_next::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1 anlegen]: %', v_res; END IF;
  v_id := (v_res->>'insurance_id')::int;
  SELECT * INTO r FROM finance.active_insurances WHERE id = v_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'FAIL [1 kommende Police fehlt in der View]'; END IF;
  IF r.annual_premium IS DISTINCT FROM 120.00 OR r.premium_amount IS DISTINCT FROM 120.00
     OR r.account_name IS DISTINCT FROM '__vai_acct__' OR r.valid_from IS DISTINCT FROM v_next THEN
    RAISE EXCEPTION 'FAIL [1 Werte]: %', row_to_json(r); END IF;
  RAISE NOTICE 'PASS [1 erste Abbuchung in der Zukunft -> sichtbar, Beitrag und Konto gefuellt]';

  -- (2)
  v_res := finance.fn_create_insurance(jsonb_build_object('name', '__vai aehnlich__', 'insurance_company', '__vai AG__',
             'premium_amount', '120', 'schedule_unit', 'year', 'debit_account_id', v_acct, 'first_payment_date', v_next::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR jsonb_array_length(COALESCE(v_res->'card_lines', '[]'::jsonb)) = 0 THEN
    RAISE EXCEPTION 'FAIL [2 Dubletten-Hinweis]: %', v_res; END IF;
  RAISE NOTICE 'PASS [2 Dubletten-Hinweis sieht die kommende Police]';

  -- (3)
  v_res := finance.fn_create_insurance(jsonb_build_object('name', '__vai laeuft__', 'insurance_company', '__vai2 AG__',
             'premium_amount', '60', 'schedule_unit', 'year', 'debit_account_id', v_acct,
             'first_payment_date', v_next::text, 'valid_from', (current_date - 400)::text));
  v_past := (v_res->>'insurance_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.active_insurances WHERE id = v_past) THEN RAISE EXCEPTION 'FAIL [3 laufende Police]: %', v_res; END IF;
  RAISE NOTICE 'PASS [3 Beginn in der Vergangenheit -> sichtbar]';

  -- (4)
  v_res := finance.fn_create_insurance(jsonb_build_object('name', '__vai gekuendigt__', 'insurance_company', '__vai3 AG__',
             'premium_amount', '70', 'schedule_unit', 'year', 'debit_account_id', v_acct, 'first_payment_date', v_next::text));
  v_off := (v_res->>'insurance_id')::int;
  UPDATE finance.insurances SET status = 'cancelled' WHERE id = v_off;
  IF EXISTS (SELECT 1 FROM finance.active_insurances WHERE id = v_off) THEN RAISE EXCEPTION 'FAIL [4 gekuendigt sichtbar]'; END IF;
  RAISE NOTICE 'PASS [4 Status nicht aktiv -> nicht sichtbar]';

  -- (5)
  v_res := finance.fn_create_insurance(jsonb_build_object('name', '__vai beendet__', 'insurance_company', '__vai4 AG__',
             'premium_amount', '80', 'schedule_unit', 'year', 'debit_account_id', v_acct,
             'first_payment_date', (current_date - 100)::text, 'valid_from', (current_date - 400)::text));
  v_ended := (v_res->>'insurance_id')::int;
  SELECT recurring_payment_id INTO v_rp FROM finance.insurances WHERE id = v_ended;
  UPDATE finance.recurring_payments SET valid_to = current_date + 30 WHERE id = v_rp;
  IF NOT EXISTS (SELECT 1 FROM finance.active_insurances WHERE id = v_ended) THEN RAISE EXCEPTION 'FAIL [5 Ende in der Zukunft]'; END IF;
  UPDATE finance.recurring_payments SET valid_to = current_date WHERE id = v_rp;
  IF EXISTS (SELECT 1 FROM finance.active_insurances WHERE id = v_ended) THEN RAISE EXCEPTION 'FAIL [5 beendet sichtbar]'; END IF;
  RAISE NOTICE 'PASS [5 Vertragsende erreicht -> nicht sichtbar, Ende in der Zukunft -> sichtbar]';
END $$;
ROLLBACK;
