-- tests/db/finance/test_fn_import_bundle.sql
-- Testet den atomaren Commit der Bulk-Import-Pipeline (Phase 2):
--   * Happy path: ein Batch (Konten inkl. Eroeffnungssaldo + Depot + Bestands-Buy + Dauerauftrag
--     + Versicherung + Immobilie + Vorsorge + Sparziel) -> ALLE Entitaeten in einem Rutsch,
--     In-Batch-Referenzen aufgeloest, Trigger-Post-State korrekt.
--   * Atomaritaet: EIN fauler Row (nach Validate manipuliert = TOCTOU-Simulation) ->
--     {ok:false, errors[]} als DATEN (kein RAISE nach aussen -> kein Owner-Alert),
--     NICHTS committed, Staging bleibt intakt (Re-Approval = 1 Button).
--   * Guards: invalid/staged Rows -> {ok:false}; unbekannter Batch -> {ok:false};
--     Doppel-Commit -> {ok:false}.
BEGIN;

DO $$
DECLARE
  v_result JSONB;
  v_batch  UUID;
  v_cnt    INT;
  v_bal    NUMERIC;
  v_shares NUMERIC;
  v_err    TEXT;
BEGIN

  -- ---------- Fixture: Haushalt mit einer eindeutig aufloesbaren Person (Personen-Felder wie im Einzel-Tool) ----------
  INSERT INTO agent.core_contexts (name, description, agent_name, load_strategy, content, metadata)
  VALUES ('family', 'test fixture', NULL, 'lazy', E'## Prosa',
          jsonb_build_object('managed_by', 'agent', 'protected', true, 'render_fn', 'fn_household_context',
            'facts', jsonb_build_object('persons', jsonb_build_array(
              jsonb_build_object('person_id','__imp_erika','first_name','Impa','last_name','Testfrau',
                                 'role','owner','birth_date','1980-01-01','as_of','2026-10-21'),
              jsonb_build_object('person_id','__imp_kid','first_name','Impi','last_name','Testfrau',
                                 'role','child','birth_date','2015-01-01','as_of','2026-10-21')))))
  ON CONFLICT (name) DO UPDATE   -- Personen ANHAENGEN (Bestands-Fixture-Personen bleiben projiziert)
    SET metadata = jsonb_set(agent.core_contexts.metadata, '{facts,persons}',
          COALESCE(agent.core_contexts.metadata->'facts'->'persons', '[]'::jsonb) || (EXCLUDED.metadata->'facts'->'persons'));

  -- Audit Paket 3: Sparziel braucht ein Sparkonto -> ein BESTEHENDES Tagesgeld als reserve_account
  -- (Name ausserhalb des '__test_imp %'-Musters, damit die Konten-Zaehlung unten unveraendert bleibt).
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__imp_pot__','cash','EUR','active');

  -- ---------- Batch stagen (alle 8 Entity-Typen ausser loan; In-Batch-Referenzen) ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'source', 'chat',
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Giro','account_type','cash',
                         'bank','DKB','owner_person','Impa Testfrau','opening_balance',2500),
      jsonb_build_object('entity_type','account','name','__test_imp Depot','account_type','stocks_depot',
                         'settlement_account','__test_imp Giro','owner_person','Impa Testfrau'),
      jsonb_build_object('entity_type','stock_buy','depot','__test_imp Depot','isin','IE00B4L5Y983',
                         'symbol','IWDA','name','iShares MSCI World','shares',10,'price_per_share',100,
                         'order_fee',0,'transaction_date','2026-06-01'),
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Gehalt','direction','income',
                         'amount',3000,'account','__test_imp Giro','schedule_unit','month',
                         'schedule_day_of_month',28,'first_payment_date','2026-01-28'),
      jsonb_build_object('entity_type','insurance','name','__test_imp Haftpflicht',
                         'insurance_company','HUK','annual_premium',89.50,'policyholder_person','Impa Testfrau',
                         'debit_account','__test_imp Giro','schedule_interval',1,
                         'first_payment_date','2026-01-03','valid_from','2026-01-01'),
      jsonb_build_object('entity_type','real_estate','name','__test_imp ETW','current_value',450000,
                         'owner_person','Impa Testfrau'),
      jsonb_build_object('entity_type','pension','name','__test_imp Riester','pension_type','riester',
                         'provider','Allianz','owner_person','Impa Testfrau','current_value',12000),
      jsonb_build_object('entity_type','savings_goal','name','__test_imp Urlaub','target_amount',5000,
                         'target_date','2027-12-31','account','__test_imp Giro','first_payment_date','2026-07-01',
                         'reserve_account','__imp_pot__','beneficiary_person','Impi Testfrau'),
      jsonb_build_object('entity_type','pension_statement','pension','__test_imp Riester',
                         'statement_date','2026-05-15','reached_claim',310.40,'projection',780.00)
    ))) INTO v_result;
  IF (v_result->>'valid')::int IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION 'FAIL bundle fixture: erwartet 9 valid Rows, got %', v_result;
  END IF;
  v_batch := (v_result->>'batch_id')::uuid;

  -- ---------- TEST 1: Commit — alles-oder-nichts, hier: alles ----------
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [happy]: got %', v_result;
  END IF;
  IF (v_result->>'committed')::int IS DISTINCT FROM 9 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [happy]: erwartet committed=9, got %', v_result;
  END IF;
  -- Post-State je angelegtem Konto: balance + currency (fuer den FX-Sofort-Fetch des Tools)
  IF (SELECT (e->>'balance')::numeric FROM jsonb_array_elements(v_result->'created') e WHERE e->>'entity_type' = 'account' AND (e->>'row_no')::int = 1) IS DISTINCT FROM 2500
     OR (SELECT e->>'currency' FROM jsonb_array_elements(v_result->'created') e WHERE e->>'entity_type' = 'account' AND (e->>'row_no')::int = 1) IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [created]: Konto-Zeile 1 braucht balance=2500 und currency=EUR, got %', v_result->'created';
  END IF;

  -- Entitaeten existieren
  IF (SELECT COUNT(*) FROM finance.accounts WHERE name LIKE '__test_imp %') <> 2
     OR NOT EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__test_imp Gehalt')
     OR NOT EXISTS (SELECT 1 FROM finance.insurances WHERE name = '__test_imp Haftpflicht')
     OR NOT EXISTS (SELECT 1 FROM finance.real_estate WHERE name = '__test_imp ETW')
     OR NOT EXISTS (SELECT 1 FROM finance.pension WHERE name = '__test_imp Riester')
     OR NOT EXISTS (SELECT 1 FROM finance.savings_goals g JOIN finance.recurring_payments rp ON rp.id = g.recurring_payment_id
                    JOIN finance.accounts a ON a.id = rp.target_account_id
                    WHERE g.name = '__test_imp Urlaub' AND a.name = '__imp_pot__') THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [happy]: Entitäten unvollständig';
  END IF;

  -- Post-State: Giro = genannter Saldo 2500 — die importierte Depot-Position ist eine Bestandsuebernahme
  -- (Gegenbuchung), kein Geldabfluss (frueher still 2500 - 1000 = 1500, Audit-Fund 2026-10-21).
  SELECT b.balance INTO v_bal
  FROM finance.account_balances b JOIN finance.accounts a ON a.id = b.account_id
  WHERE a.name = '__test_imp Giro';
  IF v_bal IS DISTINCT FROM 2500.00 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [post-state]: Giro-Saldo erwartet 2500 (Bestandsuebernahme ohne Abfluss), got %', v_bal;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
                 WHERE a.name = '__test_imp Giro' AND t.category = 'position_takeover' AND t.amount = 1000) THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [takeover]: Gegenbuchung position_takeover +1000 fehlt';
  END IF;

  -- Personen wie im Einzel-Tool: Name -> Slug je Typ
  IF (SELECT owner_person_id FROM finance.accounts WHERE name = '__test_imp Giro') IS DISTINCT FROM '__imp_erika'
     OR (SELECT policyholder_person_id FROM finance.insurances WHERE name = '__test_imp Haftpflicht') IS DISTINCT FROM '__imp_erika'
     OR (SELECT owner_person_id FROM finance.real_estate WHERE name = '__test_imp ETW') IS DISTINCT FROM '__imp_erika'
     OR (SELECT owner_person_id FROM finance.pension WHERE name = '__test_imp Riester') IS DISTINCT FROM '__imp_erika'
     OR (SELECT beneficiary_person_id FROM finance.savings_goals WHERE name = '__test_imp Urlaub') IS DISTINCT FROM '__imp_kid' THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [persons]: Personen-Slugs nicht gesetzt';
  END IF;
  -- Versicherungs-Rate leitet die DB ab: 89.50 / Jahr (schedule_unit leer -> year) = -89.50 als Ausgabe
  IF (SELECT rp.amount FROM finance.insurances i JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
      WHERE i.name = '__test_imp Haftpflicht') IS DISTINCT FROM -89.50 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [insurance]: Rate -89.50 (abgeleitet, Ausgabe) erwartet';
  END IF;
  -- Konto mit genanntem Saldo: Stichtag gesetzt -> spaetere Raten zaehlen erst ab heute
  IF (SELECT opening_balance_date FROM finance.accounts WHERE name = '__test_imp Giro') IS DISTINCT FROM CURRENT_DATE
     OR (SELECT rp.valid_from FROM finance.insurances i JOIN finance.recurring_payments rp ON rp.id = i.recurring_payment_id
         WHERE i.name = '__test_imp Haftpflicht') IS DISTINCT FROM CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [stichtag]: opening_balance_date / Raten-valid_from = heute erwartet';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [Saldo 2500 + Gegenbuchung, Personen je Typ, Versicherungs-Rate abgeleitet, Stichtag]';

  -- Review A3: Eroeffnungsbuchung ist category='other' (NICHT 'reconciliation'), und
  -- last_reconciled_* bleibt unberuehrt (kein verfaelschter erster Reconcile-Reminder).
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
    WHERE a.name = '__test_imp Giro' AND t.category = 'other' AND t.amount = 2500
      AND t.description = 'Eröffnungssaldo'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [opening]: Eröffnungsbuchung category=other/2500 fehlt';
  END IF;
  IF EXISTS (
    SELECT 1 FROM finance.transactions t JOIN finance.accounts a ON a.id = t.account_id
    WHERE a.name = '__test_imp Giro' AND t.category = 'reconciliation'
  ) THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [opening]: unerwartete reconciliation-Buchung beim Import';
  END IF;
  IF (SELECT last_reconciled_at FROM finance.accounts WHERE name = '__test_imp Giro') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [opening]: last_reconciled_at gesetzt (verfälscht Reminder)';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [Eröffnung=category other, kein reconcile, last_reconciled_at NULL]';

  -- Holding existiert mit 10 Anteilen (Trigger-gepflegt)
  SELECT h.shares INTO v_shares
  FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
  WHERE a.name = '__test_imp Depot' AND h.isin = 'IE00B4L5Y983';
  IF v_shares IS DISTINCT FROM 10::numeric THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [holding]: erwartet 10 shares, got %', v_shares;
  END IF;

  -- Standmitteilungs-Snapshot haengt am Riester (In-Batch-Pension-Referenz)
  SELECT COUNT(*) INTO v_cnt
  FROM finance.pension_statements st
       JOIN finance.pension pe ON pe.id = st.pension_id
  WHERE pe.name = '__test_imp Riester' AND st.statement_date = DATE '2026-05-15'
    AND st.reached_claim = 310.40;
  IF v_cnt <> 1 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [pension_statement]: Snapshot fehlt';
  END IF;

  -- Staging-Rows committed
  SELECT COUNT(*) INTO v_cnt FROM finance.import_staging
  WHERE batch_id = v_batch AND status = 'committed';
  IF v_cnt <> 9 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [staging]: erwartet 9 committed, got %', v_cnt;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [9 Entitäten atomar inkl. pension_statement, Saldo 2500, Holding 10 Anteile]';

  -- ---------- TEST 2: Doppel-Commit -> {ok:false} ----------
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [double commit]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [Doppel-Commit -> ok:false]';

  -- ---------- TEST 3: Atomaritaet — 1 fauler Row rollt ALLES zurueck, {ok:false} als Daten ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Tagesgeld','account_type','cash',
                         'opening_balance',8000),
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Spotify','direction','expense',
                         'amount',11,'account','__test_imp Tagesgeld','schedule_unit','month',
                         'first_payment_date','2026-01-05')
    ))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF (v_result->>'valid')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL atomicity fixture: erwartet 2 valid, got %', v_result;
  END IF;
  -- TOCTOU-Simulation: Row 2 NACH dem Validate kaputt machen (negativer Betrag passiert die fn-Guard nicht)
  UPDATE finance.import_staging
  SET payload = jsonb_set(payload, '{amount}', '-11')
  WHERE batch_id = v_batch AND row_no = 2;

  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [atomicity]: erwartet ok=false, got %', v_result;
  END IF;
  IF v_result->'errors'->0->>'row_no' IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [atomicity]: errors[] ohne row_no, got %', v_result;
  END IF;
  -- NICHTS wurde committed: Konto existiert nicht, Staging-Rows unveraendert (kein committed)
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__test_imp Tagesgeld') THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [atomicity]: Konto trotz Fehler angelegt (kein Voll-Rollback)';
  END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.import_staging
  WHERE batch_id = v_batch AND status = 'committed';
  IF v_cnt <> 0 THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [atomicity]: % Rows committed trotz Rollback', v_cnt;
  END IF;
  IF v_result->>'error_summary' IS NULL OR v_result->>'error_summary' NOT LIKE 'Zeile %' THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [atomicity]: error_summary fehlt/unformatiert (A11), got %', v_result->>'error_summary';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [Atomarität: 1 fauler Row -> Voll-Rollback + errors[row_no] + error_summary]';

  -- ---------- TEST 3b: loan-Happy-Path (Reihenfolge-Index 2, vorher ungetestet) ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Girokredit','account_type','cash',
                         'opening_balance',0),
      jsonb_build_object('entity_type','loan','name','__test_imp Autokredit','original_amount',20000,
                         'current_balance',15000,'interest_rate',4.5,'debit_account','__test_imp Girokredit',
                         'disbursement_date','2024-01-01','monthly_annuity',350,'lender','Santander',
                         'first_payment_date','2026-11-01','schedule_day_of_month',1)
    ))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF (v_result->>'valid')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL loan fixture: erwartet 2 valid, got %', v_result;
  END IF;
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [loan]: got %', v_result;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.loans WHERE name = '__test_imp Autokredit') THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [loan]: Kredit nicht angelegt';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [loan-Happy-Path: Kredit + debit_account-Referenz aufgelöst]';

  -- ---------- TEST 3b2: laufender Kredit nur mit Restschuld/Zins/Rate (Ursprungswerte optional, Live-Befund 2026-10-24) ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','loan','name','__test_imp Laufkredit','current_balance',8000,'interest_rate',2.5,
                         'debit_account','__test_imp Girokredit','monthly_annuity',250,'lender','Testbank',
                         'first_payment_date','2026-11-28','schedule_day_of_month',-2),
      -- frischer Kredit ohne Betrag bleibt ungueltig
      jsonb_build_object('entity_type','loan','name','__test_imp Frisch ohne Betrag','interest_rate',2.5,
                         'debit_account','__test_imp Girokredit','disbursement_date','2026-01-02'),
      -- frisch OHNE Auszahlungsdatum (WP2): gueltig -- eroeffnet zum Stichtag heute, Datum spaeter nachtragbar
      jsonb_build_object('entity_type','loan','name','__test_imp Frisch gleich','original_amount',9000,'current_balance',9000,
                         'interest_rate',2.5,'debit_account','__test_imp Girokredit'),
      -- Rate unter dem Monatszins (8000 * 2,5 % / 12 = 16,67) -> ungueltig vor der Karte
      jsonb_build_object('entity_type','loan','name','__test_imp Rate zu klein','current_balance',8000,'interest_rate',2.5,
                         'debit_account','__test_imp Girokredit','monthly_annuity',10,'first_payment_date','2026-11-28')
    ))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF (v_result->>'valid')::int IS DISTINCT FROM 2 OR (v_result->>'invalid')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL import laufender Kredit: erwartet 2 valid + 2 invalid, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate_row [laufender Kredit ohne Ursprungswerte + frisch ohne Datum gueltig; frisch ohne Betrag, Rate < Zins ungueltig]';

  -- ---------- TEST 3c: ambiger Konto-Name im Bundle -> {ok:false} (Two-Pass-Resolve) ----------
  -- zwei aktive Bestands-Konten gleichen Namens -> Referenz aus einer recurring_payment-Row ambig
  INSERT INTO finance.accounts (name, account_type) VALUES
    ('__test_imp Doppel', 'cash'), ('__test_imp Doppel', 'cash');
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Abo','direction','expense',
                         'amount',10,'account','__test_imp Doppel','schedule_unit','month',
                         'first_payment_date','2026-01-01'))
  )) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  -- Validate laesst es durch (fn_import_ref_account akzeptiert hit_count>=1 als 'db'); der Bundle-
  -- Resolver (fn_resolve_account, eindeutig) faengt die Ambiguitaet -> {ok:false}, kein Write.
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false
     OR v_result->>'error_summary' NOT ILIKE '%ambiguous%' THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [ambiguous]: erwartet ok=false/ambiguous, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__test_imp Abo') THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [ambiguous]: Dauerauftrag trotz Ambiguität angelegt';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [ambiger Konto-Name -> ok:false, kein Write]';

  -- ---------- TEST 4: Batch mit invalid Rows -> {ok:false} ohne Write ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','insurance','name','__test_imp Unvollständig','premium_amount',12))  -- ohne Rhythmus/Konto/Datum
  )) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [invalid rows]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [invalid Rows -> ok:false ohne Write]';

  -- ---------- TEST 4b: Validierung spiegelt die Einzel-Tool-Regeln (Fehler VOR dem Gate) ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Alt','account_type','cash','owner','Impa Testfrau'),
      jsonb_build_object('entity_type','account','name','__test_imp Unbekannt','account_type','cash','owner_person','Niemand Da'),
      jsonb_build_object('entity_type','account','name','__test_imp Kredit','account_type','loan'),
      jsonb_build_object('entity_type','insurance','name','__test_imp Rate','annual_premium',100,
                         'debit_account','__test_imp Giro','first_payment_date','2026-01-01','recurring_amount',-100),
      jsonb_build_object('entity_type','loan','name','__test_imp Lauf','original_amount',20000,'current_balance',15000,
                         'interest_rate',4,'debit_account','__test_imp Giro','disbursement_date','2020-01-01',
                         'disbursement_account','__test_imp Giro'),
      jsonb_build_object('entity_type','stock_buy','depot','__test_imp Depot','isin','IE00B4L5Y983','symbol','IWDA',
                         'shares',5,'price_per_share',90)
    ))) INTO v_result;
  SELECT string_agg(row_no || ':' || COALESCE(validation_error, 'VALID'), ' | ' ORDER BY row_no) INTO v_err
  FROM finance.import_staging WHERE batch_id = (v_result->>'batch_id')::uuid;
  IF v_err NOT LIKE '1:%owner_person%' OR v_err NOT LIKE '%2:%matches 0 household%'
     OR v_err NOT LIKE '%3:%entity_type loan%' OR v_err NOT LIKE '%4:%recurring_amount%derived%'
     OR v_err NOT LIKE '%5:%disbursement_account%' OR v_err NOT LIKE '%6:%already holds 10%' THEN
    RAISE EXCEPTION 'FAIL fn_import_validate_row [Einzel-Tool-Paritaet]: %', v_err;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate_row [alte Keys, Person 0 Treffer, loan-Konto, recurring_amount, Auszahlung bei laufendem Kredit, Doppel-Position]';

  -- EUR-Pflicht Versicherung/Kredit schon vor dem Gate (sonst Voll-Rollback NACH der Freigabe); Waehrung eines
  -- Depots ohne eigene Angabe = die seines Verrechnungskontos (fn_import_ref_currency = Karte = fn_create_account)
  INSERT INTO finance.currencies (code) VALUES ('USD') ON CONFLICT DO NOTHING;
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp USD-Cash','account_type','cash','currency','USD','opening_balance',100),
      jsonb_build_object('entity_type','account','name','__test_imp USD-Depot','account_type','stocks_depot','settlement_account','__test_imp USD-Cash'),
      jsonb_build_object('entity_type','insurance','name','__test_imp USD-Police','annual_premium',100,
                         'debit_account','__test_imp USD-Cash','first_payment_date','2026-01-01'),
      jsonb_build_object('entity_type','loan','name','__test_imp USD-Kredit','original_amount',1000,'interest_rate',3,
                         'debit_account','__test_imp USD-Cash','disbursement_date','2026-01-01')
    ))) INTO v_result;
  SELECT string_agg(row_no || ':' || COALESCE(validation_error, 'VALID'), ' | ' ORDER BY row_no) INTO v_err
  FROM finance.import_staging WHERE batch_id = (v_result->>'batch_id')::uuid;
  IF v_err NOT LIKE '1:VALID | 2:VALID | 3:%kept in EUR% | 4:%kept in EUR%' THEN
    RAISE EXCEPTION 'FAIL fn_import_validate_row [EUR-Pflicht]: %', v_err;
  END IF;
  IF finance.fn_import_ref_currency((v_result->>'batch_id')::uuid, '__test_imp USD-Depot') IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL fn_import_ref_currency: Depot ohne Waehrung muss USD seines Verrechnungskontos erben';
  END IF;
  RAISE NOTICE 'PASS fn_import_validate_row [EUR-Pflicht Versicherung/Kredit vor dem Gate, Depot erbt Verrechnungs-Waehrung]';

  -- ---------- TEST 5: unbekannter Batch -> {ok:false} ----------
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', gen_random_uuid())) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_bundle [unknown batch]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [unbekannter Batch -> ok:false]';

END $$;

-- ============================================================
-- PROBELAUF (Import-Haertung 2026-10-22): dry_run:true laeuft durch denselben Write-Loop und rollt IMMER zurueck.
-- Owner-Befund: die Karte sah gut aus, der Fehler kam erst nach dem Bestaetigen (Krypto ohne Bezeichnung).
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_batch  UUID;
  v_cnt    INT;
BEGIN
  -- [DR1] gueltiger Krypto-Batch (Bestandsuebernahme OHNE Bezeichnung) -> ok:true, dry_run:true, NICHTS geschrieben
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr Verrechnung','account_type','cash','opening_balance',0),
    jsonb_build_object('entity_type','account','name','__dr Krypto','account_type','crypto_depot',
                       'settlement_account','__dr Verrechnung'),
    jsonb_build_object('entity_type','stock_buy','depot','__dr Krypto','symbol','BTC',
                       'shares',0.06127493,'price_per_share',54218),
    jsonb_build_object('entity_type','stock_buy','depot','__dr Krypto','symbol','ETH',
                       'shares',0.71925384,'price_per_share',1846.30)))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch AND status = 'valid') <> 4 THEN
    RAISE EXCEPTION 'FAIL [DR1]: alle 4 Zeilen muessen valide gestaged sein, got %', v_result;
  END IF;

  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch, 'dry_run', true)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'dry_run')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [DR1]: Probelauf eines gueltigen Batches muss ok:true, dry_run:true liefern, got %', v_result;
  END IF;
  SELECT count(*) INTO v_cnt FROM finance.accounts WHERE name LIKE '__dr %';
  IF v_cnt <> 0 OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE symbol IN ('BTC','ETH')
                             AND account_id IN (SELECT id FROM finance.accounts WHERE name LIKE '__dr %')) THEN
    RAISE EXCEPTION 'FAIL [DR1]: Probelauf darf nichts schreiben (Konten: %)', v_cnt;
  END IF;
  IF (SELECT count(*) FROM finance.import_staging WHERE batch_id = v_batch AND status = 'valid') <> 4 THEN
    RAISE EXCEPTION 'FAIL [DR1]: Staging-Status muss nach dem Probelauf unveraendert valid sein';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR1 Probelauf gueltig -> ok, nichts geschrieben, Staging unveraendert]';

  -- [DR2] danach der ECHTE Commit desselben Batches -> ok, 4 committed, Name = Symbol (kein Rest des Probelaufs)
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'committed')::int IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL [DR2]: echter Commit nach dem Probelauf muss 4 Zeilen committen, got %', v_result;
  END IF;
  IF (SELECT h.shares FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
       WHERE a.name = '__dr Krypto' AND h.symbol = 'BTC') IS DISTINCT FROM 0.06127493
     OR (SELECT h.name FROM finance.depot_holdings h JOIN finance.accounts a ON a.id = h.account_id
          WHERE a.name = '__dr Krypto' AND h.symbol = 'ETH') IS DISTINCT FROM 'ETH' THEN
    RAISE EXCEPTION 'FAIL [DR2]: BTC 0.06127493 Stueck und ETH mit Namen "ETH" erwartet';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR2 echter Commit nach Probelauf -> 4 committed, 8 Nachkommastellen, Name = Symbol]';

  -- [DR3] fehlerhafte Zeile (Zinssatz auf einem Depot) -> ok:false, dry_run:true, errors[row_no], nichts geschrieben
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr3 Giro','account_type','cash','opening_balance',100),
    jsonb_build_object('entity_type','account','name','__dr3 Depot','account_type','stocks_depot',
                       'settlement_account','__dr3 Giro','interest_rate',2)))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch, 'dry_run', true)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR (v_result->>'dry_run')::boolean IS DISTINCT FROM true
     OR (v_result->'errors'->0->>'row_no')::int IS DISTINCT FROM 2 OR NULLIF(v_result->>'error_summary','') IS NULL THEN
    RAISE EXCEPTION 'FAIL [DR3]: Zins auf Depot muss im Probelauf als Fehler in Zeile 2 erscheinen, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name LIKE '__dr3 %') THEN
    RAISE EXCEPTION 'FAIL [DR3]: fehlerhafter Probelauf darf nichts schreiben';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR3 Zins auf Depot -> Fehler Zeile 2 vor der Karte]';

  -- [DR3b] Live-Befund 2026-10-24: verzinstes Konto ohne Gutschrift-Rhythmus -> korrigierbarer Fehler der Zeile
  -- (kein still erfundenes "jaehrlich"); die gueltige Zeile davor bleibt unberuehrt, nichts geschrieben.
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr3b Giro','account_type','cash','opening_balance',100),
    jsonb_build_object('entity_type','account','name','__dr3b Tagesgeld','account_type','cash','opening_balance',500,
                       'interest_rate',2.25)))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch, 'dry_run', true)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR (v_result->'errors'->0->>'row_no')::int IS DISTINCT FROM 2
     OR v_result->>'error_summary' NOT LIKE '%interest_credit_unit%' THEN
    RAISE EXCEPTION 'FAIL [DR3b]: Zins ohne Rhythmus muss im Probelauf als Fehler in Zeile 2 erscheinen, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name LIKE '__dr3b %') THEN
    RAISE EXCEPTION 'FAIL [DR3b]: fehlerhafter Probelauf darf nichts schreiben';
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR3b Zins ohne Rhythmus -> Fehler Zeile 2 vor der Karte]';

  -- [DR4] dieselbe Position zweimal im Batch -> Probelauf meldet die zweite Zeile
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr4 Giro','account_type','cash','opening_balance',0),
    jsonb_build_object('entity_type','account','name','__dr4 Krypto','account_type','crypto_depot',
                       'settlement_account','__dr4 Giro'),
    jsonb_build_object('entity_type','stock_buy','depot','__dr4 Krypto','symbol','ETH','shares',1,'price_per_share',1000),
    jsonb_build_object('entity_type','stock_buy','depot','__dr4 Krypto','symbol','ETH','shares',2,'price_per_share',1000)
  ))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch, 'dry_run', true)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR (v_result->'errors'->0->>'row_no')::int IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL [DR4]: doppelte Position muss als Fehler in Zeile 4 erscheinen, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR4 Positions-Dublette im Batch -> Zeile 4]';

  -- [DR5] derselbe ETF-NAME in zwei Depots ist legitim (keine Namens-Dublette bei stock_buy)
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr5 Giro','account_type','cash','opening_balance',0),
    jsonb_build_object('entity_type','account','name','__dr5 Depot A','account_type','stocks_depot','settlement_account','__dr5 Giro'),
    jsonb_build_object('entity_type','account','name','__dr5 Depot B','account_type','stocks_depot','settlement_account','__dr5 Giro'),
    jsonb_build_object('entity_type','stock_buy','depot','__dr5 Depot A','isin','IE00B4L5Y983','symbol','IWDA',
                       'name','iShares MSCI World','shares',1,'price_per_share',100),
    jsonb_build_object('entity_type','stock_buy','depot','__dr5 Depot B','isin','IE00B4L5Y983','symbol','IWDA',
                       'name','iShares MSCI World','shares',2,'price_per_share',100)))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_batch AND status <> 'valid') THEN
    RAISE EXCEPTION 'FAIL [DR5]: gleicher ETF-Name in zwei Depots darf keine Dublette sein, got %',
      (SELECT jsonb_agg(validation_error) FROM finance.import_staging WHERE batch_id = v_batch);
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR5 gleicher ETF-Name in zwei Depots -> valide]';

  -- [DR6] abgelehnte Immobilie (unbekannter Status) gilt nicht mehr als "angelegt"
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','real_estate','name','__dr6 ETW','current_value',300000,'status','owned')
  ))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  IF EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_batch AND status = 'valid') THEN
    SELECT finance.fn_import_bundle(jsonb_build_object('batch_id', v_batch)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.real_estate WHERE name = '__dr6 ETW') THEN
      RAISE EXCEPTION 'FAIL [DR6]: unbekannter Immobilien-Status muss ok:false liefern und nichts anlegen, got %', v_result;
    END IF;
  END IF;
  RAISE NOTICE 'PASS fn_import_bundle [DR6 Immobilie mit unbekanntem Status -> abgelehnt, nicht angelegt]';

  -- [DR7] fn_import_depot_currency (Yahoo-Listing vor der Karte): Depot aus DEMSELBEN Batch, case-insensitiv, ohne eigene
  -- Waehrung -> Waehrung seines Verrechnungskontos (USD); bestehendes Konto exakt wie fn_resolve_account (eine andere
  -- Schreibweise meldet der Probelauf als "not found"); unbekannt -> EUR.
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr7 USD Cash','account_type','cash','currency','usd','opening_balance',0),
    jsonb_build_object('entity_type','account','name','__dr7 IBKR Depot','account_type','stocks_depot',
                       'settlement_account','__dr7 usd cash')))) INTO v_result;
  v_batch := (v_result->>'batch_id')::uuid;
  PERFORM finance.fn_ensure_currency('CHF');
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__dr7 Bestand CHF','cash','CHF','active');
  IF finance.fn_import_depot_currency(v_batch, '__dr7 ibkr depot') IS DISTINCT FROM 'USD'
     OR finance.fn_import_depot_currency(v_batch, '__dr7 Bestand CHF') IS DISTINCT FROM 'CHF'
     OR finance.fn_import_depot_currency(v_batch, '__dr7 gibt es nicht') IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [DR7]: USD (Batch-Depot ueber Verrechnungskonto) / CHF (Bestand) / EUR (unbekannt) erwartet, got % / % / %',
      finance.fn_import_depot_currency(v_batch, '__dr7 ibkr depot'), finance.fn_import_depot_currency(v_batch, '__dr7 Bestand CHF'),
      finance.fn_import_depot_currency(v_batch, '__dr7 gibt es nicht');
  END IF;
  -- Verrechnungskonto ist eine Batch-Zeile OHNE Waehrung (= EUR) -> EUR, kein Durchfall auf ein gleichnamiges USD-Bestandskonto
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__dr7 Giro','cash','USD','active');
  SELECT finance.fn_import_stage(jsonb_build_object('source', 'chat', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__dr7 Giro','account_type','cash','opening_balance',0),
    jsonb_build_object('entity_type','account','name','__dr7 Depot EUR','account_type','stocks_depot',
                       'settlement_account','__dr7 Giro')))) INTO v_result;
  IF finance.fn_import_depot_currency((v_result->>'batch_id')::uuid, '__dr7 Depot EUR') IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [DR7b]: Batch-Verrechnungskonto ohne Waehrung muss EUR liefern, nicht die des gleichnamigen Bestandskontos';
  END IF;
  RAISE NOTICE 'PASS fn_import_depot_currency [DR7 Batch-Depot case-insensitiv -> USD, Bestand -> CHF, unbekannt -> EUR, kein Durchfall]';
END $$;

ROLLBACK;
