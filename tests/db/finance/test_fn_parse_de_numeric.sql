-- tests/db/finance/test_fn_parse_de_numeric.sql
-- Review LM2/A4: deterministische Normalisierung deutscher/plain Zahl-Strings, damit der
-- nachgelagerte ::numeric-Cast nie an "4.200,50" scheitert. Plus: die Normalisierung im
-- Staging-Write (fn_import_normalize_payload) macht "4.200,50" auf opening_balance castbar.
BEGIN;

DO $$
DECLARE
  v JSONB;
BEGIN
  -- ---------- fn_parse_de_numeric: Kernfaelle ----------
  IF finance.fn_parse_de_numeric('4.200,50', true) <> '4200.50' THEN RAISE EXCEPTION 'FAIL DE both -> %', finance.fn_parse_de_numeric('4.200,50', true); END IF;
  IF finance.fn_parse_de_numeric('4200,50', true)  <> '4200.50' THEN RAISE EXCEPTION 'FAIL DE comma -> %', finance.fn_parse_de_numeric('4200,50', true); END IF;
  IF finance.fn_parse_de_numeric('4200.50', true)  <> '4200.50' THEN RAISE EXCEPTION 'FAIL plain dot -> %', finance.fn_parse_de_numeric('4200.50', true); END IF;
  IF finance.fn_parse_de_numeric('4200', true)     <> '4200'    THEN RAISE EXCEPTION 'FAIL plain int -> %', finance.fn_parse_de_numeric('4200', true); END IF;
  IF finance.fn_parse_de_numeric('4.200', true)    <> '4200'    THEN RAISE EXCEPTION 'FAIL DE thousands -> %', finance.fn_parse_de_numeric('4.200', true); END IF;
  IF finance.fn_parse_de_numeric('4.2', true)      <> '4.2'     THEN RAISE EXCEPTION 'FAIL decimal dot -> %', finance.fn_parse_de_numeric('4.2', true); END IF;
  IF finance.fn_parse_de_numeric('1.234.567', true)<> '1234567' THEN RAISE EXCEPTION 'FAIL multi-dot thousands -> %', finance.fn_parse_de_numeric('1.234.567', true); END IF;
  IF finance.fn_parse_de_numeric('1.234.567,89', true) <> '1234567.89' THEN RAISE EXCEPTION 'FAIL big DE -> %', finance.fn_parse_de_numeric('1.234.567,89', true); END IF;
  IF finance.fn_parse_de_numeric('4.200,50 €', true) <> '4200.50' THEN RAISE EXCEPTION 'FAIL currency strip -> %', finance.fn_parse_de_numeric('4.200,50 €', true); END IF;
  IF finance.fn_parse_de_numeric('1.234,56 EUR', true) <> '1234.56' THEN RAISE EXCEPTION 'FAIL EUR strip -> %', finance.fn_parse_de_numeric('1.234,56 EUR', true); END IF;
  IF finance.fn_parse_de_numeric('-89,50', true)   <> '-89.50'  THEN RAISE EXCEPTION 'FAIL neg -> %', finance.fn_parse_de_numeric('-89,50', true); END IF;
  IF finance.fn_parse_de_numeric('', true)         <> ''        THEN RAISE EXCEPTION 'FAIL empty'; END IF;
  IF finance.fn_parse_de_numeric(NULL, true)       IS NOT NULL  THEN RAISE EXCEPTION 'FAIL null'; END IF;
  -- jeder Output ist ein gueltiger ::numeric-Cast (ausser leer)
  PERFORM ('4200.50')::numeric, ('1234567.89')::numeric, ('-89.50')::numeric;
  RAISE NOTICE 'PASS fn_parse_de_numeric [DE both/comma/thousands/multi-dot/currency/neg + plain]';

  -- ---------- Audit-Fund 2026-10-21: Nicht-Geld-Felder ohne Tausender-Heuristik + Vorzeichen ----------
  IF finance.fn_parse_de_numeric('0.125', false) <> '0.125' THEN RAISE EXCEPTION 'FAIL plain 0.125 -> %', finance.fn_parse_de_numeric('0.125', false); END IF;
  IF finance.fn_parse_de_numeric('3.125', false) <> '3.125' THEN RAISE EXCEPTION 'FAIL plain 3.125 -> %', finance.fn_parse_de_numeric('3.125', false); END IF;
  IF finance.fn_parse_de_numeric('0,125', false) <> '0.125' THEN RAISE EXCEPTION 'FAIL plain 0,125 -> %', finance.fn_parse_de_numeric('0,125', false); END IF;
  IF finance.fn_parse_de_numeric('1.234,56-', true) <> '-1234.56' THEN RAISE EXCEPTION 'FAIL trailing minus -> %', finance.fn_parse_de_numeric('1.234,56-', true); END IF;
  IF finance.fn_parse_de_numeric('−1.234,56', true) <> '-1234.56' THEN RAISE EXCEPTION 'FAIL unicode minus -> %', finance.fn_parse_de_numeric('−1.234,56', true); END IF;
  RAISE NOTICE 'PASS fn_parse_de_numeric [plain-Modus ohne Tausenderpunkt, nachgestelltes + Unicode-Minus]';

  -- JSON-Zahlen bleiben unberuehrt; Strings in Stueck/Kurs/Zins dezimal; Geld weiter mit Tausenderpunkt
  v := finance.fn_import_normalize_payload('stock_buy',
        jsonb_build_object('symbol','BTC','shares',0.125,'price_per_share','1.234','order_fee','1.000'));
  IF (v->>'shares')::numeric <> 0.125 OR (v->>'price_per_share')::numeric <> 1.234 OR (v->>'order_fee')::numeric <> 1000 THEN
    RAISE EXCEPTION 'FAIL normalize stock_buy (0.125 / 1.234 / 1.000 Geld): %', v;
  END IF;
  v := finance.fn_import_normalize_payload('account',
        jsonb_build_object('name','X','account_type','cash','interest_rate','3.125','opening_balance',1142.5));
  IF (v->>'interest_rate')::numeric <> 3.125 OR (v->>'opening_balance')::numeric <> 1142.5 THEN
    RAISE EXCEPTION 'FAIL normalize account (Zins 3.125 / JSON-Zahl 1142.5): %', v;
  END IF;
  -- idempotent: zweimal normalisieren = einmal (update_row normalisiert das ganze Payload erneut)
  v := finance.fn_import_normalize_payload('stock_buy', jsonb_build_object('shares','0,125','order_fee','4.200,50'));
  IF finance.fn_import_normalize_payload('stock_buy', v) <> v OR (v->>'shares')::numeric <> 0.125 THEN
    RAISE EXCEPTION 'FAIL normalize nicht idempotent: % -> %', v, finance.fn_import_normalize_payload('stock_buy', v);
  END IF;
  RAISE NOTICE 'PASS fn_import_normalize_payload [JSON-Zahl unberuehrt, Stueck/Kurs/Zins dezimal, idempotent]';

  -- ---------- fn_import_normalize_payload: nur Zahl-Felder, je Typ ----------
  v := finance.fn_import_normalize_payload('account',
        jsonb_build_object('name','X','account_type','cash','opening_balance','4.200,50','bank','DKB'));
  IF v->>'opening_balance' <> '4200.50' OR v->>'bank' <> 'DKB' OR v->>'name' <> 'X' THEN
    RAISE EXCEPTION 'FAIL normalize account: %', v;
  END IF;
  v := finance.fn_import_normalize_payload('recurring_payment',
        jsonb_build_object('name','Miete','amount','1.250','direction','expense','schedule_unit','month'));
  IF v->>'amount' <> '1250' OR v->>'direction' <> 'expense' THEN
    RAISE EXCEPTION 'FAIL normalize recurring: %', v;
  END IF;
  RAISE NOTICE 'PASS fn_import_normalize_payload [Zahl-Felder kanonisiert, Rest unberuehrt]';

  -- ---------- End-to-end: deutsche Zahl im Stage -> valid (frueher Cast-FAIL) ----------
  v := finance.fn_import_stage(jsonb_build_object(
    'rows', jsonb_build_array(
      jsonb_build_object('entity_type','account','name','__test_imp DE-Giro','account_type','cash',
                         'opening_balance','4.200,50'))));
  IF (v->>'valid')::int <> 1 THEN
    RAISE EXCEPTION 'FAIL DE stage: erwartet 1 valid (Normalisierung), got %', v;
  END IF;
  IF (SELECT payload->>'opening_balance' FROM finance.import_staging
      WHERE batch_id = (v->>'batch_id')::uuid AND row_no = 1) <> '4200.50' THEN
    RAISE EXCEPTION 'FAIL DE stage: opening_balance nicht normalisiert gespeichert';
  END IF;
  RAISE NOTICE 'PASS fn_import_stage [deutsche Zahl 4.200,50 -> valid + normalisiert gespeichert]';

  -- Zeilen-Korrektur darf bereits normalisierte Stueckzahlen nicht erneut umdeuten (0,125 -> 0.125 -> 125)
  DECLARE v_b UUID; v_cash INT; BEGIN
    INSERT INTO finance.accounts (name, account_type) VALUES ('__test_imp NUM-Cash', 'cash') RETURNING id INTO v_cash;
    INSERT INTO finance.accounts (name, account_type, settlement_account_id) VALUES ('__test_imp NUM-Depot', 'crypto_depot', v_cash);
    v := finance.fn_import_stage(jsonb_build_object('rows', jsonb_build_array(
      jsonb_build_object('entity_type','stock_buy','depot','__test_imp NUM-Depot','symbol','BTC',
                         'shares','0,125','price_per_share','50000'))));
    v_b := (v->>'batch_id')::uuid;
    PERFORM finance.fn_import_update_row(jsonb_build_object('batch_id', v_b, 'row_no', 1,
      'payload_merge', jsonb_build_object('order_fee','1,50')));
    IF (SELECT (payload->>'shares')::numeric FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1) <> 0.125 THEN
      RAISE EXCEPTION 'FAIL update_row re-normalisiert shares falsch: %',
        (SELECT payload FROM finance.import_staging WHERE batch_id = v_b AND row_no = 1);
    END IF;
  END;
  RAISE NOTICE 'PASS fn_import_update_row [Korrektur laesst 0,125 Stueck bei 0.125]';

  -- Rundungs-Paket 2026-10-23: Exponent korrekt lesen (vorher "1e-7" -> "17"); "1,234" als GELD mehrdeutig
  -- (engl. Tausender vs. dt. Dezimal) -> Rohwert, der Cast meldet den Zeilenfehler; als Stueck/Kurs eindeutig dezimal.
  IF finance.fn_parse_de_numeric('1e-7', false)::numeric IS DISTINCT FROM 0.0000001
     OR finance.fn_parse_de_numeric('2E3', true)::numeric IS DISTINCT FROM 2000 THEN
    RAISE EXCEPTION 'FAIL Exponent: 1e-7 -> %, 2E3 -> %', finance.fn_parse_de_numeric('1e-7', false), finance.fn_parse_de_numeric('2E3', true);
  END IF;
  IF finance.fn_parse_de_numeric('1,234', true) IS DISTINCT FROM '1,234'
     OR finance.fn_parse_de_numeric('1,234', false) IS DISTINCT FROM '1.234'
     OR finance.fn_parse_de_numeric('1,23', true) IS DISTINCT FROM '1.23' THEN
    RAISE EXCEPTION 'FAIL Komma-3: Geld % / Stueck % / Geld 1,23 %', finance.fn_parse_de_numeric('1,234', true),
      finance.fn_parse_de_numeric('1,234', false), finance.fn_parse_de_numeric('1,23', true);
  END IF;
  -- Exponent mit Waehrung wird gelesen, mit anderer Einheit nicht still verfaelscht (Rohwert -> Zeilenfehler)
  IF finance.fn_parse_de_numeric('2E3 €', true)::numeric IS DISTINCT FROM 2000
     OR finance.fn_parse_de_numeric('1e-7 BTC', false) IS DISTINCT FROM '1e-7 BTC' THEN
    RAISE EXCEPTION 'FAIL Exponent+Einheit: 2E3 € -> %, 1e-7 BTC -> %', finance.fn_parse_de_numeric('2E3 €', true),
      finance.fn_parse_de_numeric('1e-7 BTC', false);
  END IF;
  -- Import: Stueck auf 8 Stellen (sichtbar auf der Karte); mehrdeutiger Gesamt-Einstand bleibt als Preis-Rohwert
  IF (finance.fn_import_normalize_payload('stock_buy', '{"shares":"0,123456789012","price_per_share":"10"}'::jsonb)->>'shares')::numeric
       IS DISTINCT FROM 0.12345679
     OR finance.fn_import_normalize_payload('stock_buy', '{"shares":"10","cost_basis_total":"643,220"}'::jsonb)->>'price_per_share'
       IS DISTINCT FROM '643,220' THEN
    RAISE EXCEPTION 'FAIL normalize: %, %',
      finance.fn_import_normalize_payload('stock_buy', '{"shares":"0,123456789012","price_per_share":"10"}'::jsonb),
      finance.fn_import_normalize_payload('stock_buy', '{"shares":"10","cost_basis_total":"643,220"}'::jsonb);
  END IF;
  RAISE NOTICE 'PASS fn_parse_de_numeric [1e-7 -> 0.0000001; 1,234 Geld -> Rohwert, Stueck -> 1.234; Einheiten; Import-Stueck 8 Stellen]';

END $$;

ROLLBACK;
