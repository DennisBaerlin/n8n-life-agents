-- tests/db/finance/test_fn_create_insurance.sql
-- Testet fn_create_insurance: recurring_payment anlegen + insurance verknüpfen, atomar; WP2: Beitrag je Abbuchung roh,
-- Jahres-/Monatswert abgeleitet (keine Kopie an der Police), Beitrag Pflicht, Rundungs-Toleranz
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_acct_id  INT;
  v_rp_id    INT;
  v_ins_id   INT;
  v_monthly  NUMERIC;
BEGIN

  -- Voraussetzung: Debit-Konto
  SELECT finance.fn_create_account(
    '{"name":"__test_ins_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- fn_create_insurance aufrufen (1200 EUR Jahresprämie = 100 EUR/Monat)
  SELECT finance.fn_create_insurance(
    jsonb_build_object(
      'name',                  '__test_haftpflicht__',
      'insurance_company',     'TestVersicherung AG',
      'policy_number',         'TV-0001',
      'policyholder',          'Test',
      'annual_premium',        '1200',
      'schedule_interval',     '1',
      'schedule_unit',         'month',
      'schedule_day_of_month', '1',
      'valid_from',            '2024-01-01',
      'first_payment_date',    '2024-01-01',
      'debit_account_id',      v_acct_id
    )
  ) INTO v_result;   -- Rate je Abbuchung leitet die fn ab: 1200 / 12 = 100 (kein recurring_amount mehr)

  IF NOT (v_result ? 'insurance_id') THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance: kein insurance_id in Result, got %', v_result;
  END IF;
  v_ins_id := (v_result->>'insurance_id')::int;
  v_rp_id  := (v_result->>'recurring_payment_id')::int;

  -- Assert: recurring_payment existiert mit korrektem Betrag
  IF NOT EXISTS (
    SELECT 1 FROM finance.recurring_payments
    WHERE id = v_rp_id AND account_id = v_acct_id AND amount = -100
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance: recurring_payment nicht korrekt angelegt (rp_id=%)', v_rp_id;
  END IF;

  -- Assert: insurance.recurring_payment_id verknüpft
  IF NOT EXISTS (
    SELECT 1 FROM finance.insurances
    WHERE id = v_ins_id AND recurring_payment_id = v_rp_id
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance: insurance.recurring_payment_id nicht gesetzt (ins_id=%)', v_ins_id;
  END IF;

  -- Assert: Monats-/Jahreswert ABGELEITET aus der Beitrags-Zeile (WP2: keine Kopie an der Police)
  SELECT monthly_equivalent INTO v_monthly
  FROM finance.active_insurances WHERE id = v_ins_id;
  IF (SELECT annual_premium FROM finance.active_insurances WHERE id = v_ins_id) IS DISTINCT FROM 1200.00
     OR (v_result->>'monthly_equivalent')::numeric IS DISTINCT FROM 100.00 OR (v_result->>'premium_amount')::numeric IS DISTINCT FROM 100.00 THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance: Jahreswert 1200 / Return 100 erwartet, got %', v_result; END IF;

  IF v_monthly IS DISTINCT FROM 100 THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance: monthly_equivalent sollte 100, got %', v_monthly;
  END IF;

  RAISE NOTICE 'PASS fn_create_insurance: ins_id=%, rp_id=%, monthly=%', v_ins_id, v_rp_id, v_monthly;

  -- Assert (WS-4): die obige Police ohne policyholder_person_id -> NULL = Haushalt.
  IF NOT EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_ins_id AND policyholder_person_id IS NULL) THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [ph]: ohne policyholder_person_id muss NULL=Haushalt sein';
  END IF;
  -- Mit typisiertem Versicherungsnehmer (Slug):
  INSERT INTO agent.persons (person_id, full_name, role)
  VALUES ('__test_ins_ph', 'Test Nehmer', 'partner') ON CONFLICT (person_id) DO NOTHING;
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_haftpflicht_ph__','policyholder_person_id','__test_ins_ph','annual_premium','600',
    'schedule_unit','year','schedule_day_of_month','1','valid_from','2024-01-01','first_payment_date','2024-01-01',
    'debit_account_id',v_acct_id,'recurring_amount','-50'
  )) INTO v_result;
  v_ins_id := (v_result->>'insurance_id')::int;
  IF NOT EXISTS (SELECT 1 FROM finance.insurances WHERE id = v_ins_id AND policyholder_person_id = '__test_ins_ph') THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [ph2]: policyholder_person_id nicht gesetzt (id=%)', v_ins_id;
  END IF;
  RAISE NOTICE 'PASS fn_create_insurance [policyholder_person_id Slug gesetzt + NULL=Haushalt]';

  -- WS-0b (estate): die additiven Nachlass-Felder persistieren via fn_create_insurance.
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_haftpflicht_estate__','insurance_type','accident','beneficiary','Kinder',
    'coverage_amount','150000','claim_deadline_hours','48','annual_premium','240','schedule_unit','year',
    'schedule_day_of_month','1','valid_from','2024-01-01','first_payment_date','2024-01-01',
    'debit_account_id',v_acct_id,'recurring_amount','-20'
  )) INTO v_result;
  v_ins_id := (v_result->>'insurance_id')::int;
  IF NOT EXISTS (
    SELECT 1 FROM finance.insurances
    WHERE id = v_ins_id AND insurance_type = 'accident' AND beneficiary = 'Kinder'
      AND coverage_amount = 150000 AND claim_deadline_hours = 48
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [estate-Felder]: insurance_type/beneficiary/coverage_amount/claim_deadline_hours nicht gesetzt (id=%)', v_ins_id;
  END IF;
  RAISE NOTICE 'PASS fn_create_insurance [estate-Felder insurance_type/beneficiary/coverage_amount/claim_deadline_hours persistiert]';

  -- Import-Haertung 2026-10-22: ungueltiger insurance_type -> {ok:false} OHNE Write (vorher CHECK-RAISE/Owner-Alert);
  -- der CHECK bleibt der strukturelle Backstop (Direkt-UPDATE unten).
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_bad_type__','insurance_type','not_a_type','annual_premium','120','schedule_unit','year',
    'schedule_day_of_month','1','valid_from','2024-01-01','first_payment_date','2024-01-01',
    'debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.insurances WHERE name = '__test_bad_type__') THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [type-guard]: ok:false ohne Write erwartet, got %', v_result;
  END IF;
  BEGIN
    UPDATE finance.insurances SET insurance_type = 'not_a_type' WHERE id = v_ins_id;
    RAISE EXCEPTION 'FAIL fn_create_insurance [type-CHECK]: Direkt-UPDATE haette den CHECK verletzen muessen';
  EXCEPTION WHEN check_violation THEN NULL;
  END;
  RAISE NOTICE 'PASS fn_create_insurance [insurance_type: fn -> ok:false, CHECK-Backstop greift]';

  -- Import-Haertung: Summe < 0, Meldefrist kein ganze Stundenzahl, unbekannter Rhythmus, Belastung vom Depot
  -- -> jeweils {ok:false} ohne Write; Text "50.000" -> 50000 (Tausenderpunkt), JSON-Zahl 50.000 bleibt 50.
  DECLARE v_depot INT; v_case JSONB; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, settlement_account_id)
    VALUES ('__test_ins_depot__', 'stocks_depot', 'EUR', v_acct_id) RETURNING id INTO v_depot;
    FOREACH v_case IN ARRAY ARRAY[
        jsonb_build_object('coverage_amount', '-1'),
        jsonb_build_object('claim_deadline_hours', '48h'),
        jsonb_build_object('claim_deadline_hours', '0'),
        jsonb_build_object('schedule_unit', 'yearly'),
        jsonb_build_object('debit_account_id', v_depot)] LOOP
      SELECT finance.fn_create_insurance(jsonb_build_object(
        'name','__test_ins_guard__','annual_premium','120','first_payment_date','2024-01-01',
        'debit_account_id',v_acct_id) || v_case) INTO v_result;
      IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.insurances WHERE name = '__test_ins_guard__') THEN
        RAISE EXCEPTION 'FAIL fn_create_insurance [guard %]: ok:false ohne Write erwartet, got %', v_case, v_result;
      END IF;
    END LOOP;
    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_txt__','annual_premium','1.200',
      'coverage_amount','50.000','first_payment_date','2024-01-01','debit_account_id',v_acct_id)) INTO v_result;
    IF (SELECT abs(rp.amount)::text || '|' || i.coverage_amount::text FROM finance.insurances i
         JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
         WHERE i.id = (v_result->>'insurance_id')::int) IS DISTINCT FROM '1200.00|50000.00' THEN
      RAISE EXCEPTION 'FAIL fn_create_insurance [parse text]: "1.200"/"50.000" -> 1200/50000 erwartet, got %', v_result;
    END IF;
    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_num__','annual_premium',120,
      'coverage_amount',50.000,'first_payment_date','2024-01-01','debit_account_id',v_acct_id)) INTO v_result;
    IF (SELECT coverage_amount FROM finance.insurances WHERE id = (v_result->>'insurance_id')::int) IS DISTINCT FROM 50 THEN
      RAISE EXCEPTION 'FAIL fn_create_insurance [parse number]: JSON-Zahl 50.000 muss 50 bleiben, got %', v_result;
    END IF;
  END;
  RAISE NOTICE 'PASS fn_create_insurance [Guards Summe/Frist/Rhythmus/Depot -> ok:false; "50.000" -> 50000, Zahl 50.000 -> 50]';

  -- Eindeutigkeit 2026-10-21: ein mitgeliefertes (falsches, POSITIVES) recurring_amount wird ignoriert;
  -- ohne schedule_unit gilt 'year', ohne valid_from gilt first_payment_date.
  SELECT finance.fn_create_insurance(jsonb_build_object(
    'name','__test_ins_derive__','annual_premium','89.50','first_payment_date','2026-01-03',
    'debit_account_id',v_acct_id,'recurring_amount','89.50')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT amount FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int) IS DISTINCT FROM -89.50
     OR (SELECT rp.schedule_unit::text || '|' || i.valid_from FROM finance.insurances i JOIN finance.recurring_payments rp
         ON rp.id = i.recurring_payment_id WHERE i.id = (v_result->>'insurance_id')::int)
        IS DISTINCT FROM 'year|2026-01-03' THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [derive]: Rate -89.50, Einheit year, valid_from 2026-01-03 erwartet, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_insurance [Rate abgeleitet (Ausgabe), recurring_amount ignoriert, Defaults year/valid_from]';

  -- Ohne erstes Datum -> ok:false
  SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_nodate__','annual_premium','100',
    'debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [nodate]: ok=false erwartet, got %', v_result;
  END IF;

  -- Nur Vertragsbeginn, kein erstes Abbuchungsdatum -> ok:false (Owner-Entscheid 2026-10-23: nachfragen; der stille
  -- Rueckfall auf valid_from verschob die Faelligkeit bei abweichender Abbuchung -> falsche Liquiditaetsvorschau)
  SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_startonly__','annual_premium','100',
    'valid_from','2026-01-01','debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'reason' NOT LIKE '%first_payment_date%' THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [nur valid_from]: ok=false mit first_payment_date erwartet, got %', v_result;
  END IF;

  -- Fremdwaehrungs-Abbuchungskonto -> ok:false (Praemie ist EUR nach Modell), kein Write
  DECLARE v_usd INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_ins_usd__","account_type":"cash","currency":"USD"}'::jsonb)->>'account_id')::int INTO v_usd;
    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_usd_pol__','annual_premium','100',
      'first_payment_date','2026-01-01','debit_account_id',v_usd)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false
       OR EXISTS (SELECT 1 FROM finance.insurances WHERE name = '__test_ins_usd_pol__') THEN
      RAISE EXCEPTION 'FAIL fn_create_insurance [usd]: ok=false ohne Write erwartet, got %', v_result;
    END IF;
  END;
  RAISE NOTICE 'PASS fn_create_insurance [ohne Datum / USD-Konto -> ok:false]';

  -- Stichtag: Konto mit genanntem Saldo -> Rate zaehlt erst ab heute (Anker bleibt in der Vergangenheit)
  DECLARE v_open INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_ins_open__","account_type":"cash","opening_balance":500}'::jsonb)->>'account_id')::int INTO v_open;
    SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_running__','annual_premium','120',
      'schedule_unit','month','first_payment_date','2020-01-15','valid_from','2020-01-01','debit_account_id',v_open)) INTO v_result;
    IF (SELECT valid_from::text || '|' || first_payment_date FROM finance.recurring_payments
        WHERE id = (v_result->>'recurring_payment_id')::int) IS DISTINCT FROM CURRENT_DATE::text || '|2020-01-15'
       OR (SELECT valid_from FROM finance.insurances WHERE id = (v_result->>'insurance_id')::int) <> DATE '2020-01-01' THEN
      RAISE EXCEPTION 'FAIL fn_create_insurance [stichtag]: Rate ab heute, Anker 2020-01-15, Police ab 2020-01-01 erwartet';
    END IF;
  END;
  RAISE NOTICE 'PASS fn_create_insurance [laufender Vertrag auf Konto mit Eroeffnungssaldo -> Rate ab Stichtag]';

  -- WP2 (das LLM rechnet nicht): "30 EUR monatlich" = Betrag je Abbuchung roh; Jahres-/Monatswert leitet die DB ab.
  SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_30m__','premium_amount',30,
    'schedule_unit','month','first_payment_date','2026-01-01','debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT amount FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int) IS DISTINCT FROM -30.00
     OR (SELECT annual_premium::text || '|' || monthly_equivalent || '|' || premium_amount FROM finance.active_insurances
         WHERE id = (v_result->>'insurance_id')::int) IS DISTINCT FROM '360.00|30.00|30.00'
     OR (v_result->>'annual_premium')::numeric IS DISTINCT FROM 360.00 THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [30 monatlich]: rp -30, Jahr 360, Monat 30 erwartet, got %', v_result; END IF;
  -- Betrag je Abbuchung ohne Rhythmus -> ok:false (sonst still 30 im Jahr); unstimmige Doppelangabe -> ok:false
  FOREACH v_result IN ARRAY ARRAY[
      finance.fn_create_insurance(jsonb_build_object('name','__test_ins_nounit__','premium_amount',30,
        'first_payment_date','2026-01-01','debit_account_id',v_acct_id)),
      finance.fn_create_insurance(jsonb_build_object('name','__test_ins_mismatch__','premium_amount',30,'annual_premium',300,
        'schedule_unit','month','first_payment_date','2026-01-01','debit_account_id',v_acct_id))] LOOP
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL fn_create_insurance [premium guard]: ok:false erwartet, got %', v_result; END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM finance.insurances WHERE name IN ('__test_ins_nounit__', '__test_ins_mismatch__')) THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [premium guard]: Write trotz ok:false'; END IF;
  -- konsistente Doppelangabe ok (Jahresbeitrag 120 monatlich = 10 je Abbuchung)
  IF (finance.fn_create_insurance(jsonb_build_object('name','__test_ins_both__','premium_amount',10,'annual_premium',120,
        'schedule_unit','month','first_payment_date','2026-01-01','debit_account_id',v_acct_id))->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [konsistent]'; END IF;
  -- Rundung des Versicherers: 1000 im Jahr monatlich = 83,33 rechnerisch, 83,34 genannt -> innerhalb 0,01 ok (Abbuchung gilt)
  SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_round__','premium_amount',83.34,'annual_premium',1000,
    'schedule_unit','month','first_payment_date','2026-01-01','debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT amount FROM finance.recurring_payments WHERE id = (v_result->>'recurring_payment_id')::int) IS DISTINCT FROM -83.34 THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [Rundung]: got %', v_result; END IF;
  -- ohne Beitrag -> ok:false (der Beitrag ist Pflicht)
  SELECT finance.fn_create_insurance(jsonb_build_object('name','__test_ins_free__','insurance_type','life',
    'first_payment_date','2026-01-01','debit_account_id',v_acct_id)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.insurances WHERE name = '__test_ins_free__') THEN
    RAISE EXCEPTION 'FAIL fn_create_insurance [ohne Beitrag]: ok:false erwartet, got %', v_result; END IF;
  RAISE NOTICE 'PASS fn_create_insurance [WP2: 30 monatlich roh -> 360/30 abgeleitet; ohne Rhythmus/unstimmig/ohne Beitrag ok:false; Rundung 0,01 ok]';

END $$;

ROLLBACK;
