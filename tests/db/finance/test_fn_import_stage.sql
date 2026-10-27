-- tests/db/finance/test_fn_import_stage.sql
-- Testet die Staging-Schicht der Bulk-Import-Pipeline (Phase 2 Onboarding-Plan):
--   * fn_import_stage      (Batch anlegen/erweitern + Auto-Validate; {ok:false} fuer Korrigierbares)
--   * fn_import_validate   (per-Row: Pflichtfelder, Enum-/Datums-/Zahlen-Casts, Dubletten-Backstop,
--                           Referenz-Aufloesung inkl. In-Batch-Konten)
--   * fn_import_update_row (Korrektur VOR dem Gate: Key-Merge/Row-Delete + Revalidate)
-- Alles BEGIN...ROLLBACK; Namen tragen __test_imp als Marker.
BEGIN;

DO $$
DECLARE
  v_result  JSONB;
  v_batch   UUID;
  v_status  TEXT;
  v_err     TEXT;
  v_acct_id INT;
BEGIN

  -- Fixture: ein BESTEHENDES Konto fuer den Dubletten-Backstop
  INSERT INTO finance.accounts (name, account_type)
  VALUES ('__test_imp Bestandskonto', 'cash')
  RETURNING id INTO v_acct_id;

  -- ---------- TEST 1: happy path — 2 Konten + 1 Dauerauftrag (In-Batch-Referenz) ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'source', 'chat',
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Giro','account_type','cash',
                         'bank','DKB','opening_balance',1000),
      jsonb_build_object('entity_type','account','name','__test_imp Depot','account_type','stocks_depot',
                         'settlement_account','__test_imp Giro'),
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Gehalt','direction','income',
                         'amount',3000,'account','__test_imp Giro','schedule_unit','month',
                         'first_payment_date','2026-01-01')
    ))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true
     OR (v_result->>'staged')::int IS DISTINCT FROM 3
     OR (v_result->>'valid')::int  IS DISTINCT FROM 3
     OR (v_result->>'invalid')::int IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_import_stage [happy]: erwartet 3/3 valid, got %', v_result;
  END IF;
  v_batch := (v_result->>'batch_id')::uuid;
  RAISE NOTICE 'PASS fn_import_stage [3 Rows staged+valid, In-Batch-Settlement-Referenz erkannt]';

  -- ---------- TEST 2: korrigierbar — unbekannter entity_type -> {ok:false}, kein Insert ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(jsonb_build_object('entity_type','spaceship','name','x'))
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_stage [unknown type]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_stage [unbekannter entity_type -> ok:false]';

  -- ---------- TEST 3: Dubletten-Backstop — bestehende Entitaet gleichen Namens -> Row invalid ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'batch_id', v_batch,
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Bestandskonto','account_type','cash'))
  )) INTO v_result;
  IF (v_result->>'invalid')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL Dubletten-Backstop: erwartet 1 invalid, got %', v_result;
  END IF;
  SELECT validation_error INTO v_err FROM finance.import_staging
  WHERE batch_id = v_batch AND row_no = 4;
  IF v_err NOT ILIKE '%exist%' THEN
    RAISE EXCEPTION 'FAIL Dubletten-Backstop: Fehlertext unklar: %', v_err;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [Dubletten-Backstop gegen Bestand: %]', v_err;

  -- ---------- TEST 4: fehlende Pflichtfelder + kaputte Referenz -> invalid mit klarem Grund ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'batch_id', v_batch,
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','insurance','name','__test_imp Haftpflicht','premium_amount',10,
                         'schedule_unit','month','first_payment_date','2026-01-01'),                  -- Beitrag ohne debit_account
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Miete','direction','expense',
                         'amount',900,'account','__test_imp GIBTSNICHT','schedule_unit','month',
                         'first_payment_date','2026-01-01'),                                          -- Referenz unaufloesbar
      jsonb_build_object('entity_type','recurring_payment','name','__test_imp Bonus','direction','sideways',
                         'amount',100,'account','__test_imp Giro','schedule_unit','month',
                         'first_payment_date','2026-01-01')                                           -- direction-Enum kaputt
    ))) INTO v_result;
  -- Summary ist BATCH-weit: 3 neue invalid + die Dublette aus TEST 3 = 4
  IF (v_result->>'invalid')::int IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL Pflichtfeld-/Referenz-Validierung: erwartet 4 invalid (3 neu + Dublette), got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [Pflichtfelder/Referenz/Enum -> invalid je Row, Summary batch-weit]';

  -- ---------- TEST 5: savings_goal braucht GENAU EINES von target_date/monthly_savings_rate ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'batch_id', v_batch,
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','savings_goal','name','__test_imp Urlaub','target_amount',5000,
                         'account','__test_imp Giro','first_payment_date','2026-07-01'))
  )) INTO v_result;
  SELECT validation_error INTO v_err FROM finance.import_staging
  WHERE batch_id = v_batch AND row_no = 8;
  IF v_err IS NULL THEN
    RAISE EXCEPTION 'FAIL savings_goal-Validierung: weder target_date noch rate, aber Row valid';
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [savings_goal ohne Datum/Rate -> invalid]';

  -- ---------- TEST 5b (Audit Paket 3): savings_goal ohne reserve_account bleibt invalid (Sparkonto ist Pflicht) ----------
  SELECT finance.fn_import_update_row(jsonb_build_object(
    'batch_id', v_batch, 'row_no', 8,
    'payload_merge', jsonb_build_object('target_date','2027-12-31')
  )) INTO v_result;
  SELECT validation_error INTO v_err FROM finance.import_staging WHERE batch_id = v_batch AND row_no = 8;
  IF COALESCE(v_err, '') NOT ILIKE '%reserve_account%' THEN
    RAISE EXCEPTION 'FAIL savings_goal-Validierung: ohne reserve_account erwartet Zeilenfehler, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [savings_goal ohne Sparkonto -> invalid]';

  -- ---------- TEST 5c (Sparziel-Zweckbindung 2026-10-27): Depot als Topf ohne Startbestand/Sparplan -> invalid ----------
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__test_imp Settle5c', 'cash', 'EUR', 'active');
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__test_imp Depot5c', 'stocks_depot', 'EUR', 'active', (SELECT max(id) FROM finance.accounts WHERE name = '__test_imp Settle5c'));
  SELECT finance.fn_import_update_row(jsonb_build_object(
    'batch_id', v_batch, 'row_no', 8,
    'payload_merge', jsonb_build_object('reserve_account','__test_imp Depot5c')
  )) INTO v_result;
  SELECT validation_error INTO v_err FROM finance.import_staging WHERE batch_id = v_batch AND row_no = 8;
  IF COALESCE(v_err, '') NOT ILIKE '%is a depot%' THEN
    RAISE EXCEPTION 'FAIL savings_goal-Validierung: Depot-Topf ohne already_saved/savings_plan erwartet Zeilenfehler, got %', v_err;
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [Depot-Topf ohne Startbestand/Sparplan -> invalid]';   -- TEST 6 setzt den Topf neu

  -- ---------- TEST 6: fn_import_update_row — Korrektur macht Row valid ----------
  SELECT finance.fn_import_update_row(jsonb_build_object(
    'batch_id', v_batch, 'row_no', 8,
    'payload_merge', jsonb_build_object('reserve_account','__test_imp Bestandskonto')
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_import_update_row [merge]: got %', v_result;
  END IF;
  SELECT status INTO v_status FROM finance.import_staging
  WHERE batch_id = v_batch AND row_no = 8;
  IF v_status IS DISTINCT FROM 'valid' THEN
    RAISE EXCEPTION 'FAIL fn_import_update_row [merge]: Row nicht valid nach Korrektur, status=%', v_status;
  END IF;
  RAISE NOTICE 'PASS fn_import_update_row [Key-Merge -> revalidiert -> valid]';

  -- ---------- TEST 7: fn_import_update_row — Row loeschen ----------
  SELECT finance.fn_import_update_row(jsonb_build_object(
    'batch_id', v_batch, 'row_no', 4, 'delete_row', true
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL fn_import_update_row [delete]: got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.import_staging WHERE batch_id = v_batch AND row_no = 4) THEN
    RAISE EXCEPTION 'FAIL fn_import_update_row [delete]: Row existiert noch';
  END IF;
  RAISE NOTICE 'PASS fn_import_update_row [delete_row]';

  -- ---------- TEST 8: update auf unbekannte Row -> {ok:false} ----------
  SELECT finance.fn_import_update_row(jsonb_build_object(
    'batch_id', v_batch, 'row_no', 999, 'payload_merge', '{}'::jsonb
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_import_update_row [missing row]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_import_update_row [unbekannte Row -> ok:false]';

  -- ---------- TEST 9: In-Batch-Dublette (zweimal derselbe Konto-Name im Batch) -> invalid ----------
  SELECT finance.fn_import_stage(jsonb_build_object(
    'batch_id', v_batch,
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp Giro','account_type','cash'))
  )) INTO v_result;
  SELECT validation_error INTO v_err FROM finance.import_staging
  WHERE batch_id = v_batch AND row_no = (SELECT MAX(row_no) FROM finance.import_staging WHERE batch_id = v_batch);
  IF v_err IS NULL THEN
    RAISE EXCEPTION 'FAIL In-Batch-Dublette: doppelter Name im Batch wurde valid';
  END IF;
  RAISE NOTICE 'PASS fn_import_validate [In-Batch-Dublette -> invalid]';

END $$;

-- ============================================================
-- Phase B: Modell-Eingaben -> {ok:false} statt Absturz (Build-Sentinel statt rows-Array, kaputte batch_id /
-- row_no, Sentinel statt payload_merge-Objekt).
-- ============================================================
DO $$
DECLARE r jsonb;
BEGIN
  r := finance.fn_import_stage('{"rows": "__invalid_json__"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%non-empty array%' THEN
    RAISE EXCEPTION 'FAIL guards [stage Sentinel]: %', r; END IF;
  r := finance.fn_import_stage('{"batch_id": "batch-7", "rows": [{"entity_type": "account", "name": "x", "account_type": "cash"}]}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%UUID%' THEN
    RAISE EXCEPTION 'FAIL guards [stage batch_id kaputt]: %', r; END IF;
  r := finance.fn_import_update_row('{"batch_id": "nope", "row_no": 1, "payload_merge": {}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%UUID%' THEN
    RAISE EXCEPTION 'FAIL guards [update batch_id kaputt]: %', r; END IF;
  r := finance.fn_import_update_row('{"batch_id": "00000000-0000-0000-0000-000000000000", "row_no": "sieben"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%row_no%' THEN
    RAISE EXCEPTION 'FAIL guards [update row_no kaputt]: %', r; END IF;
  RAISE NOTICE 'PASS import guards [Sentinel/batch_id/row_no -> ok:false, kein Absturz]';
END $$;

-- ============================================================
-- Phase C: Feld-Allow-List — eine Zeile traegt nur Felder, die die Bestaetigungskarte ihrer Art zeigt
-- (fn_import_bundle reicht den Payload sonst ungesehen an fn_create_*/fn_book_* weiter, z. B. order_fee_eur).
-- provider_symbol ist seit Monats-Check WP-G erlaubt: tool_commit_import setzt es aus der Yahoo-Aufloesung der ISIN
-- und die Karte zeigt es.
-- ============================================================
DO $$
DECLARE r jsonb; v_err text;
BEGIN
  r := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__test_imp_al Giro','account_type','cash','iban','DE00'),
    jsonb_build_object('entity_type','account','name','__test_imp_al Depot','account_type','stocks_depot',
                       'settlement_account','__test_imp_al Giro2'),
    jsonb_build_object('entity_type','account','name','__test_imp_al Giro2','account_type','cash','bank','DKB',
                       'account_number','DE02','currency','EUR','opening_balance',5,'interest_rate',1,
                       'interest_credit_unit','month','interest_valid_from','2026-01-01'),
    jsonb_build_object('entity_type','stock_buy','depot','__test_imp_al Depot','symbol','X','isin','IE0000000001',
                       'shares',1,'price_per_share',1,'order_fee_eur',1))));
  SELECT validation_error INTO v_err FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND row_no = 1;
  IF v_err IS NULL OR v_err NOT ILIKE '%iban%' THEN
    RAISE EXCEPTION 'FAIL allow-list [account iban]: %', v_err; END IF;
  SELECT validation_error INTO v_err FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND row_no = 4;
  IF v_err IS NULL OR v_err NOT ILIKE '%order_fee_eur%' THEN
    RAISE EXCEPTION 'FAIL allow-list [stock_buy order_fee_eur]: %', v_err; END IF;
  IF (SELECT status FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND row_no = 3) <> 'valid' THEN
    RAISE EXCEPTION 'FAIL allow-list [erlaubte Felder]: %',
      (SELECT validation_error FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND row_no = 3); END IF;
  -- jede Art hat eine Liste; der Typ-Schluessel ist immer erlaubt (fn_import_stage trennt ihn ab)
  IF EXISTS (SELECT 1 FROM unnest(ARRAY['account','stock_buy','insurance','pension','pension_statement',
               'recurring_payment','real_estate','savings_goal','loan']) t
             WHERE COALESCE(cardinality(finance.fn_import_allowed_keys(t)), 0) = 0) THEN
    RAISE EXCEPTION 'FAIL allow-list: eine Art ohne Feldliste'; END IF;
  RAISE NOTICE 'PASS import allow-list [unbekanntes Feld -> invalid mit Feldname, erlaubte Felder valid]';

  -- Typ-Pruefung erlaubter Felder: was die Karte (fn_import_card_rows) und der Commit casten, muss schon hier
  -- als Zeilenfehler auffallen — sonst bricht der Kartenbau einer "gueltigen" Zeile ab.
  r := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','__test_imp_ty A','account_type','cash','interest_rate',1,'interest_valid_from','ab sofort'),
    jsonb_build_object('entity_type','account','name','__test_imp_ty B','account_type','cash','interest_rate',1,'interest_auto_post','ja'),
    jsonb_build_object('entity_type','account','name','__test_imp_ty C','account_type','cash','interest_rate',1,'interest_credit_unit','quartal'),
    jsonb_build_object('entity_type','insurance','name','__test_imp_ty D','annual_premium',100,'debit_account','__test_imp_ty A',
                       'first_payment_date','2026-01-01','schedule_interval','2.5'))));
  IF (SELECT COUNT(*) FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid AND status = 'invalid') <> 4 THEN
    RAISE EXCEPTION 'FAIL typ-pruefung: erwartet 4 invalid, got %',
      (SELECT jsonb_agg(jsonb_build_object('row', row_no, 'status', status, 'err', validation_error)) FROM finance.import_staging WHERE batch_id = (r->>'batch_id')::uuid);
  END IF;
  IF finance.fn_import_card_rows((r->>'batch_id')::uuid) IS DISTINCT FROM '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL typ-pruefung: ungueltige Zeilen erscheinen auf der Karte'; END IF;
  RAISE NOTICE 'PASS import typ-pruefung [Datum/Ja-Nein/Kadenz/Ganzzahl falsch -> invalid, Karte bleibt leer]';
END $$;

ROLLBACK;
