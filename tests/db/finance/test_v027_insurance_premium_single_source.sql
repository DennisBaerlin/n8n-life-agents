-- tests/db/finance/test_v027_insurance_premium_single_source.sql
-- finance:V027 (WP2 "Finanzen schlank") auf einem Bestand wie v0.15.0: die Kopien annual_premium/monthly_equivalent/
-- schedule_*/valid_to/account_id an der Versicherung fallen, die Beitrags-Kette bleibt die eine Quelle. Der Test baut
-- den Zustand VOR V027 nach, fuehrt die ECHTE Migrationsdatei zweimal aus (\ir) und prueft:
--   (1) Kopie passt -> Beitrag je Abbuchung unveraendert; abgeleiteter Jahreswert in active_insurances (nach R__) folgt
--   (2) Rundungs-Cent (alter n8n-Rechenweg) -> kein Abbruch, die gebuchte rp gilt
--   (3) Vertragsende nur an der Police -> in die rp uebernommen
--   (4) Police ohne rp -> Jahresbeitrag in notes, Police bleibt (beitragsfrei)
-- Abbruch bei echter Abweichung (Pre-flight RAISE): per Code-Review + Upgrade-Probe abgenommen (db_test wertet ERROR als FAIL).
BEGIN;

ALTER TABLE finance.insurances
    ADD COLUMN annual_premium numeric(10,2),
    ADD COLUMN schedule_interval smallint NOT NULL DEFAULT 1,
    ADD COLUMN schedule_unit finance.schedule_unit,
    ADD COLUMN schedule_day_of_month smallint,
    ADD COLUMN valid_to date,
    ADD COLUMN account_id int;
ALTER TABLE finance.insurances
    ADD COLUMN monthly_equivalent numeric(8,2) GENERATED ALWAYS AS (round(annual_premium / 12.0, 2)) STORED;

DO $$
DECLARE v_giro INT; v_a INT; v_b INT; v_c INT; v_d INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__v027_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_a := (finance.fn_create_insurance(jsonb_build_object('name','__v027_a__','premium_amount',10,'schedule_unit','month',
          'first_payment_date','2026-01-01','debit_account_id',v_giro))->>'insurance_id')::int;
  v_b := (finance.fn_create_insurance(jsonb_build_object('name','__v027_b__','premium_amount',8.34,'schedule_unit','month',
          'first_payment_date','2026-01-01','debit_account_id',v_giro))->>'insurance_id')::int;
  v_c := (finance.fn_create_insurance(jsonb_build_object('name','__v027_c__','insurance_type','life'))->>'insurance_id')::int;
  v_d := (finance.fn_create_insurance(jsonb_build_object('name','__v027_d__','premium_amount',50,'schedule_unit','year',
          'first_payment_date','2026-03-01','debit_account_id',v_giro))->>'insurance_id')::int;
  -- Altbestand: Kopien wie v0.15.0
  UPDATE finance.insurances i SET annual_premium = 120, schedule_unit = 'month', account_id = v_giro WHERE i.id = v_a;
  UPDATE finance.insurances i SET annual_premium = 100, schedule_unit = 'month', account_id = v_giro WHERE i.id = v_b;  -- 8,33 vs 8,34
  UPDATE finance.insurances i SET annual_premium = 50, schedule_unit = 'year' WHERE i.id = v_c;
  UPDATE finance.insurances i SET annual_premium = 50, schedule_unit = 'year', account_id = v_giro, valid_to = '2030-03-01' WHERE i.id = v_d;
END $$;

\ir ../../../packages/finance/db/migrations/V027__insurance_premium_single_source.sql
\ir ../../../packages/finance/db/migrations/V027__insurance_premium_single_source.sql

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'finance' AND table_name = 'insurances'
             AND column_name IN ('annual_premium', 'monthly_equivalent', 'schedule_interval', 'schedule_unit',
                                 'schedule_day_of_month', 'valid_to', 'account_id')) THEN
    RAISE EXCEPTION 'FAIL [V027 Spalten]: Kopien noch vorhanden'; END IF;
  IF (SELECT rp.amount FROM finance.insurances i JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
      WHERE i.name = '__v027_a__') IS DISTINCT FROM -10.00
     OR (SELECT rp.amount FROM finance.insurances i JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
         WHERE i.name = '__v027_b__') IS DISTINCT FROM -8.34 THEN
    RAISE EXCEPTION 'FAIL [V027 (1)/(2)]: Beitrag je Abbuchung veraendert'; END IF;
  IF (SELECT rp.valid_to FROM finance.insurances i JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
      WHERE i.name = '__v027_d__') IS DISTINCT FROM DATE '2030-03-01' THEN
    RAISE EXCEPTION 'FAIL [V027 (3)]: Vertragsende nicht in die rp uebernommen'; END IF;
  IF (SELECT notes FROM finance.insurances WHERE name = '__v027_c__') NOT LIKE '%Jahresbeitrag laut Erfassung: 50.00%' THEN
    RAISE EXCEPTION 'FAIL [V027 (4)]: Jahresbeitrag ohne rp nicht in notes'; END IF;
  RAISE NOTICE 'PASS finance:V027 (Kopien weg, Beitrag unveraendert, Cent-Toleranz, Vertragsende -> rp, beitragsfrei -> Notiz, 2 Laeufe)';
END $$;

ROLLBACK;
