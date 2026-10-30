-- tests/db/finance/test_fn_create_savings_plan.sql
-- Testet fn_create_savings_plan: Depot/ISIN/Betrag/Turnus, Guards, FK-Link
BEGIN;

DO $$
DECLARE
  v_result      JSONB;
  v_settle_id   INT;
  v_depot_id    INT;
  v_crypto_id   INT;
  v_plan_id     INT;
  v_rp_id       INT;
  v_rp_amount   NUMERIC;
  v_rp_account  INT;
  v_rp_unit     TEXT;
  v_linked_rp   INT;
BEGIN

  -- Setup: Verrechnungskonto
  SELECT finance.fn_create_account(
    '{"name":"__test_sp_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_settle_id := (v_result->>'account_id')::int;

  -- Setup: Aktiendepot (stocks_depot mit settlement)
  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_sp_depot__',
    'account_type', 'stocks_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_depot_id := (v_result->>'account_id')::int;

  -- Setup: Crypto-Depot
  SELECT finance.fn_create_account(jsonb_build_object(
    'name', '__test_sp_crypto__',
    'account_type', 'crypto_depot',
    'account_holder', 'Test',
    'currency', 'EUR',
    'settlement_id', v_settle_id
  )) INTO v_result;
  v_crypto_id := (v_result->>'account_id')::int;

  -- TEST 1: Sparplan anlegen (ETF mit ISIN)
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',                    '__test_sparplan_vwce__',
    'depot_name',              '__test_sp_depot__',
    'isin',                    'IE00B3RBWM25',
    'symbol',                  'VWCE',
    'security_name',           'Vanguard FTSE All-World',
    'amount',                  100,
    'schedule_interval',       1,
    'schedule_unit',           'month',
    'schedule_day_of_month',   1,
    'first_payment_date',      '2026-07-01',
    'notes',                   'Weltportfolio'
  )) INTO v_result;

  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [anlegen]: ok=false, reason=%', v_result->>'reason';
  END IF;
  v_plan_id := (v_result->>'savings_plan_id')::int;
  v_rp_id   := (v_result->>'recurring_payment_id')::int;
  IF v_plan_id IS NULL OR v_rp_id IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [anlegen]: fehlende IDs, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [anlegen]: plan_id=%, rp_id=%', v_plan_id, v_rp_id;

  -- Assert: Plan korrekt in DB
  IF NOT EXISTS (
    SELECT 1 FROM finance.savings_plans
    WHERE id = v_plan_id AND symbol = 'VWCE' AND isin = 'IE00B3RBWM25'
      AND depot_id = v_depot_id AND recurring_payment_id = v_rp_id AND status = 'active'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan: Plan nicht korrekt in DB';
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [Plan in DB korrekt]';

  -- Assert: recurring_payment auf Verrechnungskonto, negativ, monatlich
  SELECT amount, account_id, schedule_unit::text
  INTO v_rp_amount, v_rp_account, v_rp_unit
  FROM finance.recurring_payments WHERE id = v_rp_id;

  IF v_rp_amount IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [rp_amount]: erwartet -100, got %', v_rp_amount;
  END IF;
  IF v_rp_account IS DISTINCT FROM v_settle_id THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [rp_account]: erwartet %, got %', v_settle_id, v_rp_account;
  END IF;
  IF v_rp_unit IS DISTINCT FROM 'month' THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [rp_unit]: erwartet month, got %', v_rp_unit;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [recurring_payment: amount=%, account=%, unit=%]',
    v_rp_amount, v_rp_account, v_rp_unit;

  -- TEST 2: Uniqueness-Guard (gleicher Name nochmal)
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',                  '__test_sparplan_vwce__',
    'depot_name',            '__test_sp_depot__',
    'isin',                  'IE00B3RBWM25',
    'symbol',                'VWCE',
    'security_name',         'Vanguard FTSE All-World',
    'amount',                100,
    'schedule_interval',     1,
    'schedule_unit',         'month',
    'schedule_day_of_month', 1,
    'first_payment_date',    '2026-07-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [Duplikat]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [Duplikat -> ok:false]';

  -- TEST 3: ISIN auf Crypto-Depot -> {ok:false}
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',                  '__test_sparplan_isin_crypto__',
    'depot_name',            '__test_sp_crypto__',
    'isin',                  'IE00B3RBWM25',
    'symbol',                'VWCE',
    'security_name',         'Vanguard',
    'amount',                50,
    'schedule_interval',     1,
    'schedule_unit',         'month',
    'schedule_day_of_month', 1,
    'first_payment_date',    '2026-07-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [ISIN auf Crypto]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [ISIN auf crypto_depot -> ok:false]';

  -- TEST 4: Crypto-Sparplan ohne ISIN auf crypto_depot -> OK
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',                  '__test_sparplan_btc__',
    'depot_name',            '__test_sp_crypto__',
    'symbol',                'BTC',
    'security_name',         'Bitcoin',
    'amount',                25,
    'schedule_interval',     1,
    'schedule_unit',         'month',
    'schedule_day_of_month', 1,
    'first_payment_date',    '2026-07-01'
  )) INTO v_result;
  IF NOT (v_result->>'ok')::boolean THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [Crypto]: ok=false, reason=%', v_result->>'reason';
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [Crypto ohne ISIN -> ok:true]';

  -- TEST 5: Betrag <= 0 -> {ok:false}
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name',                  '__test_sparplan_zero__',
    'depot_name',            '__test_sp_depot__',
    'symbol',                'MSCI',
    'security_name',         'iShares',
    'amount',                0,
    'schedule_interval',     1,
    'schedule_unit',         'month',
    'schedule_day_of_month', 1,
    'first_payment_date',    '2026-07-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [amount=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [amount=0 -> ok:false]';

  -- TEST 6 (Phase L WS-6): asset_class wird bei der Anlage erfasst (an die Ausfuehrung vererbt).
  DECLARE v_cls TEXT; v_plan6 INT; BEGIN
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_tagged__','depot_name','__test_sp_depot__',
      'isin','IE00BK5BQT80','symbol','VWCE2','security_name','Vanguard',
      'amount',75,'schedule_interval',1,'schedule_unit','month','first_payment_date','2026-07-01',
      'asset_class','sp500')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [asset_class ok]: %', v_result; END IF;
    v_plan6 := (v_result->>'savings_plan_id')::int;
    SELECT asset_class INTO v_cls FROM finance.savings_plans WHERE id = v_plan6;
    IF v_cls IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [asset_class set]: erwartet sp500, got %', v_cls; END IF;
    -- TEST 1-Plan ohne asset_class -> NULL (ungetaggt, periodische null_tag-Meldung als Netz)
    SELECT asset_class INTO v_cls FROM finance.savings_plans WHERE id = v_plan_id;
    IF v_cls IS NOT NULL THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [asset_class default]: ohne Eingabe muss NULL sein, got %', v_cls; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [asset_class erfasst + ohne Eingabe NULL]';
  END;

  -- TEST 7 (Phase L WS-6): ungueltiges asset_class-Format -> {ok:false}, kein Write.
  SELECT finance.fn_create_savings_plan(jsonb_build_object(
    'name','__test_sparplan_badcls__','depot_name','__test_sp_depot__',
    'isin','IE00B0M62Q58','symbol','VWRL3','security_name','Test',
    'amount',50,'schedule_interval',1,'schedule_unit','month','first_payment_date','2026-07-01',
    'asset_class','S&P 500')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [asset_class bad format]: erwartet ok=false, got %', v_result; END IF;
  IF EXISTS (SELECT 1 FROM finance.savings_plans WHERE name = '__test_sparplan_badcls__') THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [asset_class bad format]: Plan trotz ok=false angelegt'; END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [ungueltiges asset_class-Format -> ok:false, kein Write]';

  -- TEST 1-Depot ohne Inhaber (Joint/Haushalt) -> ohne genannte Person bleibt NULL
  IF (SELECT beneficiary_person_id FROM finance.savings_plans WHERE id = v_plan_id) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_create_savings_plan [Joint-Depot]: ohne Inhaber muss NULL=Haushalt bleiben'; END IF;
  RAISE NOTICE 'PASS fn_create_savings_plan [Joint-Depot ohne Person -> NULL]';

  -- TEST 8: Depot einer Person bei einer Bank mit festem Kalender (Vorbelegung) -> woechentlich = 4 feste
  -- Monatstage, Begünstigter = Depot-Inhaber, Kalender am Depot gelernt, Rueckgabe fuer die Karte.
  DECLARE v_tr INT; v_rp8 INT; v_r8 finance.recurring_payments%ROWTYPE; v_ben TEXT; BEGIN
    INSERT INTO agent.persons (person_id, full_name, role) VALUES
      ('__sp_owner', 'Pat Muster', 'owner'), ('__sp_kid', 'Kim Muster', 'child');
    INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, owner_person_id)
      VALUES ('__test_sp_tr__', 'stocks_depot', 'Trade Republic Bank GmbH', 'EUR', 'active', v_settle_id, '__sp_owner')
      RETURNING id INTO v_tr;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_weekly__','depot_name','__test_sp_tr__',
      'isin','IE00B5BMR087','symbol','CSPX','security_name','Beispiel S&P 500',
      'amount',100,'schedule_interval',1,'schedule_unit','week','first_payment_date','2026-11-02')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [8 weekly TR]: %', v_result; END IF;
    v_rp8 := (v_result->>'recurring_payment_id')::int;
    SELECT * INTO v_r8 FROM finance.recurring_payments WHERE id = v_rp8;
    IF v_r8.schedule_unit <> 'month' OR v_r8.schedule_interval <> 1 OR v_r8.schedule_day_of_month IS NOT NULL
       OR v_r8.schedule_days_of_month IS DISTINCT FROM '{2,9,16,23}'::smallint[] OR v_r8.monthly_equivalent <> -400.00 THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [8 rp]: unit=% n=% dom=% days=% me=%', v_r8.schedule_unit,
        v_r8.schedule_interval, v_r8.schedule_day_of_month, v_r8.schedule_days_of_month, v_r8.monthly_equivalent; END IF;
    IF (SELECT plan_execution_days FROM finance.accounts WHERE id = v_tr) IS DISTINCT FROM '{2,9,16,23}'::smallint[] THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [8 Depot-Kalender]: nicht gelernt'; END IF;
    SELECT beneficiary_person_id INTO v_ben FROM finance.savings_plans WHERE id = (v_result->>'savings_plan_id')::int;
    IF v_ben IS DISTINCT FROM '__sp_owner' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [8 Begünstigter]: erwartet Depot-Inhaber __sp_owner, got %', v_ben; END IF;
    IF v_result->>'beneficiary_person_id' IS DISTINCT FROM '__sp_owner' OR v_result->>'beneficiary_name' IS DISTINCT FROM 'Pat Muster'
       OR (v_result->>'monthly_amount')::numeric <> 400.00 OR v_result->>'schedule_days' IS DISTINCT FROM '2, 9, 16, 23'
       OR v_result->>'calendar_learned' IS DISTINCT FROM '2, 9, 16, 23'
       OR v_result->'effective'->>'beneficiary_person_id' IS DISTINCT FROM '__sp_owner' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [8 Rueckgabe]: %', v_result; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [8 woechentlich bei festem Kalender -> 4 Tage, 400/Monat, Inhaber]';

    -- TEST 9: genannte Person schlaegt den Inhaber; der gelernte Kalender gilt weiter (nicht neu)
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_kid__','depot_name','__test_sp_tr__',
      'isin','IE00B4L5Y983','symbol','IWDA','security_name','Beispiel Welt',
      'amount',50,'schedule_unit','week','schedule_interval',2,'first_payment_date','2026-11-09',
      'beneficiary_person_id','__sp_kid')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR v_result->>'beneficiary_person_id' IS DISTINCT FROM '__sp_kid'
       OR v_result->>'schedule_days' IS DISTINCT FROM '9, 23' OR (v_result->>'monthly_amount')::numeric <> 100.00
       OR v_result ? 'calendar_learned' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [9 Person + zweimal monatlich]: %', v_result; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [9 genannte Person + 9./23., Kalender nicht neu]';

    -- TEST 10: erste Ausfuehrung nicht auf dem Kalender -> ok:false + naechster Tag, kein Write
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_offcal__','depot_name','__test_sp_tr__',
      'isin','IE00B3XXRP09','symbol','VUSA','security_name','Beispiel',
      'amount',50,'schedule_unit','week','first_payment_date','2026-11-10')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'next_possible_date' IS DISTINCT FROM '2026-11-16'
       OR EXISTS (SELECT 1 FROM finance.savings_plans WHERE name = '__test_sparplan_offcal__') THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [10 off-calendar]: %', v_result; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [10 Start ausserhalb des Kalenders -> ok:false]';
  END;

  -- TEST 11: unbekannte Bank, woechentlich -> needs_calendar ohne Write; mit Nutzer-Antwort 'none' -> echte Woche
  DECLARE v_unk INT; v_rp11 INT; BEGIN
    INSERT INTO finance.accounts (name, account_type, bank, currency, status, settlement_account_id, owner_person_id)
      VALUES ('__test_sp_unk__', 'stocks_depot', 'Musterbroker', 'EUR', 'active', v_settle_id, '__sp_owner')
      RETURNING id INTO v_unk;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_unk__','depot_name','__test_sp_unk__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel',
      'amount',25,'schedule_unit','week','first_payment_date','2026-11-05')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR (v_result->>'needs_calendar')::boolean IS DISTINCT FROM true
       OR EXISTS (SELECT 1 FROM finance.savings_plans WHERE name = '__test_sparplan_unk__') THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [11 needs_calendar]: %', v_result; END IF;
    SELECT finance.fn_create_savings_plan(jsonb_build_object(
      'name','__test_sparplan_unk__','depot_name','__test_sp_unk__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel',
      'amount',25,'schedule_unit','week','first_payment_date','2026-11-05','depot_execution_days','none')) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_create_savings_plan [11 none]: %', v_result; END IF;
    v_rp11 := (v_result->>'recurring_payment_id')::int;
    IF (SELECT schedule_unit FROM finance.recurring_payments WHERE id = v_rp11) <> 'week'
       OR (SELECT plan_execution_days FROM finance.accounts WHERE id = v_unk) IS DISTINCT FROM '{}'::smallint[] THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [11 none]: rp/Kalender falsch'; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [11 unbekannte Bank: fragt, dann echte Woche + Kalender {}]';
  END;

  -- TEST 12: Woher kommt das Geld? (fn_savings_funding_fold) -- Konto mit 100, Plan 50/Monat ohne Zufluss -> Luecke:
  --   Probelauf zeigt Kartenzeile + Frage und verbraucht den Latch nicht; der echte Write fragt (Fehlbetrag 50);
  --   ein zweiter Plan aufs selbe Wertpapier behaelt den Aehnlich-Hinweis UND bekommt die Kartenzeile; er verschiebt das
  --   „reicht bis"-Datum (neue Lage) und fragt deshalb erneut.
  DECLARE v_s12 INT; v_p12 JSONB; BEGIN
    DELETE FROM core.notification_state WHERE source = 'finance' AND key LIKE 'savings_funding:%';
    v_s12 := (finance.fn_create_account('{"name":"__test_sp_fund_settle__","account_type":"cash","opening_balance":100}'::jsonb)->>'account_id')::int;
    PERFORM finance.fn_create_account(jsonb_build_object('name','__test_sp_fund_depot__','account_type','stocks_depot',
                                                         'settlement_id', v_s12));
    v_p12 := jsonb_build_object('name','__test_sparplan_fund__','depot_name','__test_sp_fund_depot__',
      'isin','IE00B3RBWM25','symbol','VWCE','security_name','Beispiel','amount',50,'schedule_unit','month',
      'first_payment_date', (CURRENT_DATE + 5)::text);
    v_result := core.fn_dry_run('finance.fn_create_savings_plan(jsonb)'::regprocedure, v_p12);
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'card_lines') l
                      WHERE l->>'value' IN ('finance.note.funding_gap', 'finance.note.funding_until'))
       OR NOT (v_result->'savings_funding'->'accounts'->0->>'asked')::boolean THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [12 Probelauf]: %', v_result; END IF;
    v_result := finance.fn_create_savings_plan(v_p12);
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true
       OR (v_result->'savings_funding'->'accounts'->0->>'account_id')::int <> v_s12
       OR (v_result->'savings_funding'->'accounts'->0->>'monthly_gap')::numeric <> 50
       OR NOT (v_result->'savings_funding'->'accounts'->0->>'asked')::boolean
       OR v_result->'savings_funding'->>'note' NOT LIKE '%ASK the user%' THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [12 Frage nach dem Write]: %', v_result; END IF;
    v_result := finance.fn_create_savings_plan(v_p12 || '{"name":"__test_sparplan_fund_2__","amount":10}'::jsonb);
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true
       OR NOT (v_result->'savings_funding'->'accounts'->0->>'asked')::boolean
       OR (v_result->'savings_funding'->'accounts'->0->>'monthly_gap')::numeric <> 60
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'card_lines') l WHERE l->>'value' = 'finance.note.similar_entry')
       OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_result->'card_lines') l
                      WHERE l->>'value' IN ('finance.note.funding_gap', 'finance.note.funding_until')) THEN
      RAISE EXCEPTION 'FAIL fn_create_savings_plan [12 zweiter Plan: beide Kartenzeilen, neue Lage fragt]: %', v_result; END IF;
    RAISE NOTICE 'PASS fn_create_savings_plan [12 Geldquelle: Probelauf ohne Latch, Frage je Lage, Kartenzeilen zusammengefuegt]';
  END;

END $$;

ROLLBACK;
