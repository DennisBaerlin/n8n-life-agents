-- tests/db/finance/test_v026_loan_rate_single_source.sql
-- finance:V026 (WP2 "Finanzen schlank") auf einem Bestand wie v0.15.0: die Kopien monthly_annuity/schedule_*/
-- principal_rate am Kredit fallen, die Raten-Kette bleibt die eine Quelle. Der Test baut den Zustand VOR V026 nach
-- (Alt-Spalten + alter CHECK), fuehrt die ECHTE Migrationsdatei zweimal aus (\ir; 2. Lauf = No-op) und prueft:
--   (1) Kopie = Raten-Zeile -> Rate/Tag unveraendert an der Kette, Alt-Spalten weg
--   (2) Rate OHNE Raten-Zeile (Altbestand) -> kein Abbruch: Betrag in notes, Kredit pausiert
--   (3) neuer CHECK aktiv <=> Raten-Kette
-- Den Abbruch bei abweichender Kopie (Pre-flight RAISE) kann db_test nicht als PASS werten (jedes ERROR = FAIL);
-- er ist per Code-Review + Upgrade-Probe abgenommen. BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

-- ---------- Zustand vor V026 nachbauen ----------
ALTER TABLE finance.loans
    ADD COLUMN principal_rate numeric(6,4),
    ADD COLUMN monthly_annuity numeric(10,2),
    ADD COLUMN schedule_interval smallint NOT NULL DEFAULT 1,
    ADD COLUMN schedule_unit finance.schedule_unit NOT NULL DEFAULT 'month',
    ADD COLUMN schedule_day_of_month smallint;
ALTER TABLE finance.loans DROP CONSTRAINT finance_loans_active_needs_annuity;

DO $$
DECLARE v_giro INT; v_a INT; v_c INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__v026_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;
  v_a := (finance.fn_create_loan(jsonb_build_object('name','__v026_a__','lender','Bank','current_balance',20000,
          'interest_rate',3,'monthly_annuity',400,'schedule_day_of_month',15,'first_payment_date',(CURRENT_DATE + 10)::text,
          'debit_account_id',v_giro))->>'loan_id')::int;
  v_c := (finance.fn_create_loan(jsonb_build_object('name','__v026_c__','lender','Familie','current_balance',3000,
          'interest_rate',0,'debit_account_id',v_giro))->>'loan_id')::int;
  -- Altbestand: Kopien wie v0.15.0 (Rate/Tag gespiegelt, gespeicherte anfaengliche Tilgung), Kredit C mit Rate ohne Kette
  UPDATE finance.loans l SET monthly_annuity = -rp.amount, schedule_day_of_month = rp.schedule_day_of_month, principal_rate = 2.5
    FROM finance.recurring_payments rp WHERE rp.id = l.recurring_payment_id AND l.id = v_a;
  UPDATE finance.loans SET monthly_annuity = 150, status = 'active' WHERE id = v_c;
END $$;
ALTER TABLE finance.loans ADD CONSTRAINT finance_loans_active_needs_annuity
    CHECK (monthly_annuity IS NOT NULL OR status <> 'active');

-- ---------- die ECHTE Migration (zweimal: Idempotenz) ----------
\ir ../../../packages/finance/db/migrations/V026__loan_rate_single_source.sql
\ir ../../../packages/finance/db/migrations/V026__loan_rate_single_source.sql

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'finance' AND table_name = 'loans'
             AND column_name IN ('principal_rate', 'monthly_annuity', 'schedule_interval', 'schedule_unit', 'schedule_day_of_month')) THEN
    RAISE EXCEPTION 'FAIL [V026 Spalten]: Kopien noch vorhanden'; END IF;
  IF (SELECT rp.amount::text || '|' || rp.schedule_day_of_month || '|' || l.status FROM finance.loans l
      JOIN finance.recurring_payments rp ON rp.id = l.recurring_payment_id WHERE l.name = '__v026_a__')
     IS DISTINCT FROM '-400.00|15|active' THEN
    RAISE EXCEPTION 'FAIL [V026 (1)]: Rate/Tag an der Kette veraendert'; END IF;
  IF (SELECT status::text FROM finance.loans WHERE name = '__v026_c__') IS DISTINCT FROM 'paused'
     OR (SELECT notes FROM finance.loans WHERE name = '__v026_c__') NOT LIKE '%Rate laut Erfassung: 150.00%' THEN
    RAISE EXCEPTION 'FAIL [V026 (2)]: Rate ohne Kette nicht in notes / nicht pausiert'; END IF;
  BEGIN
    UPDATE finance.loans SET status = 'active' WHERE name = '__v026_c__';
    RAISE EXCEPTION 'FAIL [V026 (3)]: aktiv ohne Raten-Kette akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  RAISE NOTICE 'PASS finance:V026 (Kopien weg, Kette unveraendert, Rate ohne Kette -> Notiz + pausiert, neuer CHECK, 2 Laeufe)';
END $$;

ROLLBACK;
