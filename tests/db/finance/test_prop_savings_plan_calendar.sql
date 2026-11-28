-- tests/db/finance/test_prop_savings_plan_calendar.sql
-- Eigenschafts-Test: Sparplan an einem Depot mit festen Ausfuehrungstagen (Depot-Kalender) ueber eine Folge von
-- Rhythmus- und Betrags-Wechseln, gegen die Vorschau (fn_upcoming_payments).
--   C1 jeder Termin eines Glieds liegt auf einem seiner festen Tage bzw. auf seinem Einzeltag und in seinem
--      Geltungszeitraum; ueber die ganze Kette ist kein Datum doppelt
--   C2 in jedem vollen Monat eines Glieds: Summe der Termine = sein Monatswert (monthly_equivalent) = Betrag x Tage
--   C3 die Rueckgabe jedes Wechsels (monthly_amount, schedule_days) nennt die Werte des neuen Glieds
--   C4 Wechsel und Kalender: woechentlich = alle Kalendertage, zweimal im Monat = jeder zweite ab dem Stichtag,
--      monatlich = der Tag des Stichtags
-- Feste Daten im Jahr 2031 (Raster und Split haengen dort nicht von "heute" ab).
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_giro INT; v_depot INT; v_rp INT; v_cal TEXT; v_n INT := 0; r RECORD; m RECORD;
  v_cals TEXT[] := ARRAY['2,9,16,23', '1,8,15,22', '5,12,19,26'];
  v_d1 INT; v_d2 INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_spc_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;

  FOREACH v_cal IN ARRAY v_cals LOOP
    BEGIN
      SELECT (finance.fn_create_account(jsonb_build_object('name','__prop_spc_depot__','account_type','stocks_depot','currency','EUR',
                'settlement_id',v_giro))->>'account_id')::int INTO v_depot;
      v_d1 := split_part(v_cal, ',', 1)::int; v_d2 := split_part(v_cal, ',', 2)::int;
      -- woechentlich ab dem ersten Kalendertag im Maerz
      v_res := finance.fn_create_savings_plan(jsonb_build_object('name','__prop_spc_plan__','depot_name','__prop_spc_depot__','isin','IE00B3RBWM25',
        'symbol','VWCE','security_name','Testfonds Welt','amount',25,'schedule_interval',1,'schedule_unit','week',
        'first_payment_date',make_date(2031, 3, v_d1),'depot_execution_days',v_cal));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'monthly_amount')::numeric IS DISTINCT FROM 100
         OR replace(v_res->>'schedule_days', ' ', '') IS DISTINCT FROM v_cal THEN
        RAISE EXCEPTION 'FAIL C3/C4 [Kalender %] woechentlich: %', v_cal, v_res - 'card_lines'; END IF;
      v_rp := (v_res->>'recurring_payment_id')::int;
      -- zweimal im Monat ab dem zweiten Kalendertag im Juni
      v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_spc_plan__','schedule_unit','week','schedule_interval',2,
        'valid_from',make_date(2031, 6, v_d2)));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'monthly_amount')::numeric IS DISTINCT FROM 50
         OR replace(v_res->>'schedule_days', ' ', '') IS DISTINCT FROM (v_d2 || ',' || split_part(v_cal, ',', 4)) THEN
        RAISE EXCEPTION 'FAIL C3/C4 [Kalender %] zweimal im Monat: %', v_cal, v_res - 'card_lines'; END IF;
      -- nur der Betrag ab Mitte Juli: die Tage bleiben
      v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_spc_plan__','new_amount',40,'valid_from','2031-07-14'));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'monthly_amount')::numeric IS DISTINCT FROM 80
         OR replace(v_res->>'schedule_days', ' ', '') IS DISTINCT FROM (v_d2 || ',' || split_part(v_cal, ',', 4)) THEN
        RAISE EXCEPTION 'FAIL C3 [Kalender %] Betrag: %', v_cal, v_res - 'card_lines'; END IF;
      -- monatlich ab dem dritten Kalendertag im September
      v_res := finance.fn_set_savings_plan(jsonb_build_object('savings_plan_name','__prop_spc_plan__','schedule_unit','month','schedule_interval',1,
        'valid_from',make_date(2031, 9, split_part(v_cal, ',', 3)::int)));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'monthly_amount')::numeric IS DISTINCT FROM 40 OR (v_res->>'schedule_days') IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL C3/C4 [Kalender %] monatlich: %', v_cal, v_res - 'card_lines'; END IF;

      IF (SELECT count(*) FROM finance.fn_recurring_lineage(v_rp)) <> 4 THEN RAISE EXCEPTION 'FAIL [Kalender %]: Kette hat nicht vier Glieder', v_cal; END IF;
      -- C1
      IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2031-12-31') u
                 JOIN finance.recurring_payments l ON l.id = u.recurring_payment_id
                 WHERE l.id IN (SELECT finance.fn_recurring_lineage(v_rp))
                   AND (u.due_date < l.valid_from OR (l.valid_to IS NOT NULL AND u.due_date >= l.valid_to)
                        OR NOT (EXTRACT(DAY FROM u.due_date)::int = ANY (COALESCE(l.schedule_days_of_month::int[], ARRAY[l.schedule_day_of_month::int])))
                        OR u.amount IS DISTINCT FROM l.amount)) THEN
        RAISE EXCEPTION 'FAIL C1 [Kalender %]: Termin ausserhalb der Tage, des Zeitraums oder mit fremdem Betrag', v_cal; END IF;
      IF (SELECT count(*) <> count(DISTINCT u.due_date) FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2031-12-31') u
           WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp))) THEN
        RAISE EXCEPTION 'FAIL C1 [Kalender %]: ein Datum ist doppelt faellig', v_cal; END IF;
      -- C2: volle Monate je Glied
      FOR r IN SELECT l.* FROM finance.recurring_payments l WHERE l.id IN (SELECT finance.fn_recurring_lineage(v_rp)) LOOP
        FOR m IN SELECT g::date AS ms FROM generate_series(DATE '2031-01-01', DATE '2031-12-01', interval '1 month') g
                 WHERE g::date >= r.valid_from AND (r.valid_to IS NULL OR (g + interval '1 month')::date <= r.valid_to) LOOP
          IF (SELECT COALESCE(sum(u.amount), 0) FROM finance.fn_upcoming_payments(m.ms, (m.ms + interval '1 month')::date - 1) u WHERE u.recurring_payment_id = r.id)
             IS DISTINCT FROM r.monthly_equivalent
             OR r.monthly_equivalent IS DISTINCT FROM r.amount * COALESCE(cardinality(r.schedule_days_of_month), 1) THEN
            RAISE EXCEPTION 'FAIL C2 [Kalender % Glied ab % Monat %]: Summe der Termine % gegen Monatswert %', v_cal, r.valid_from, m.ms,
              (SELECT sum(u.amount) FROM finance.fn_upcoming_payments(m.ms, (m.ms + interval '1 month')::date - 1) u WHERE u.recurring_payment_id = r.id), r.monthly_equivalent; END IF;
        END LOOP;
      END LOOP;
      v_n := v_n + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;
  RAISE NOTICE 'PASS prop savings plan calendar [% Depot-Kalender, je vier Glieder, C1-C4]', v_n;
END $$;

ROLLBACK;
