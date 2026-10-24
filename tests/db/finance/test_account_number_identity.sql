-- tests/db/finance/test_account_number_identity.sql
-- Monats-Check WP-B: eindeutige Zuordnung per Kontonummer/IBAN + Schluessel je Dauerauftrag.
--   (1) fn_normalize_account_number: Leerzeichen raus, Grossbuchstaben, leer -> NULL
--   (2) fn_create_account speichert normalisiert; gleiche Nummer bei aktivem Konto -> {ok:false}, kein Write
--   (3) DB-Backstop: CHECK "normalisiert" + partieller UNIQUE (aktive Konten) -> Direkt-DML scheitert
--   (4) fn_set_account: Kollision -> {ok:false}; eigene Nummer erneut setzen ist ok
--   (5) fn_resolve_account_by_number: exakt (mit Leerzeichen eingegeben), Fallback letzte 4 Stellen nur cash + eindeutig
--   (6) recurring_payment_keys: SEPA-Mandat global eindeutig, Gegen-IBAN je Dauerauftrag (zwei rps, gleiche IBAN ok)
--   (7) Import: Konto-Zeile mit schon vergebener IBAN -> Zeilenfehler nennt das bestehende Konto
BEGIN;

DO $$
DECLARE v_res JSONB; v_a INT; v_b INT; v_c INT; v_rp1 INT; v_rp2 INT; r RECORD;
BEGIN
  -- (1)
  IF finance.fn_normalize_account_number(' de12 3456 7890 ') IS DISTINCT FROM 'DE1234567890'
     OR finance.fn_normalize_account_number('   ') IS NOT NULL
     OR finance.fn_normalize_account_number(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL (1) normalize: %', finance.fn_normalize_account_number(' de12 3456 7890 '); END IF;
  RAISE NOTICE 'PASS (1) normalize';

  -- (2)
  v_res := finance.fn_create_account('{"name":"__t_ani_giro__","account_type":"cash","currency":"EUR","account_number":"de02 1001 0010 0006 8201 01"}'::jsonb);
  v_a := (v_res->>'account_id')::int;
  IF (SELECT account_number FROM finance.accounts WHERE id = v_a) IS DISTINCT FROM 'DE02100100100006820101' THEN
    RAISE EXCEPTION 'FAIL (2) gespeichert nicht normalisiert: %', (SELECT account_number FROM finance.accounts WHERE id = v_a); END IF;
  v_res := finance.fn_create_account('{"name":"__t_ani_dup__","account_type":"cash","currency":"EUR","account_number":"DE02100100100006820101"}'::jsonb);
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%__t_ani_giro__%' THEN
    RAISE EXCEPTION 'FAIL (2) Dublette: %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__t_ani_dup__') THEN RAISE EXCEPTION 'FAIL (2): Write trotz Dublette'; END IF;
  RAISE NOTICE 'PASS (2) create normalisiert + Dublette {ok:false}';

  -- (3) Backstop
  BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, account_number) VALUES ('__t_ani_raw__', 'cash', 'EUR', 'de99 1');
    RAISE EXCEPTION 'FAIL (3): nicht-normalisierte Nummer akzeptiert';
  EXCEPTION WHEN check_violation THEN NULL; END;
  BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, account_number) VALUES ('__t_ani_raw2__', 'cash', 'EUR', 'DE02100100100006820101');
    RAISE EXCEPTION 'FAIL (3): doppelte aktive Nummer akzeptiert';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  RAISE NOTICE 'PASS (3) CHECK + UNIQUE als Backstop';

  -- (4)
  v_res := finance.fn_create_account('{"name":"__t_ani_tg__","account_type":"cash","currency":"EUR","account_number":"DE11520513735120710131"}'::jsonb);
  v_b := (v_res->>'account_id')::int;
  v_res := finance.fn_set_account(jsonb_build_object('account_id', v_b, 'account_number', 'DE02 1001 0010 0006 8201 01'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL (4) set Kollision: %', v_res; END IF;
  v_res := finance.fn_set_account(jsonb_build_object('account_id', v_b, 'account_number', 'de11 5205 1373 5120 7101 31'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL (4) eigene Nummer: %', v_res; END IF;
  RAISE NOTICE 'PASS (4) set_account Kollision {ok:false}, eigene Nummer ok';

  -- (5)
  SELECT * INTO r FROM finance.fn_resolve_account_by_number('DE02 1001 0010 0006 8201 01');
  IF r.id IS DISTINCT FROM v_a OR r.hit_count <> 1 THEN RAISE EXCEPTION 'FAIL (5) exakt: %', r; END IF;
  -- Kreditkarte: maskierte Nummer, nur letzte 4 Stellen gedruckt
  v_res := finance.fn_create_account('{"name":"__t_ani_cc__","account_type":"cash","currency":"EUR","account_number":"4111111111114711"}'::jsonb);
  v_c := (v_res->>'account_id')::int;
  SELECT * INTO r FROM finance.fn_resolve_account_by_number('XXXX XXXX XXXX 4711');
  IF r.id IS DISTINCT FROM v_c THEN RAISE EXCEPTION 'FAIL (5) letzte 4: %', r; END IF;
  SELECT * INTO r FROM finance.fn_resolve_account_by_number('DE36 0000 0000 0000 0000 00');
  IF r.id IS NOT NULL OR r.hit_count <> 0 THEN RAISE EXCEPTION 'FAIL (5) unbekannt: %', r; END IF;
  -- vollstaendige fremde IBAN mit denselben Endziffern -> kein Endziffern-Treffer (Review-Befund)
  SELECT * INTO r FROM finance.fn_resolve_account_by_number('DE94 5001 0517 0000 0047 11');
  IF r.id IS NOT NULL OR r.hit_count <> 0 THEN RAISE EXCEPTION 'FAIL (5) volle IBAN darf nicht per Endziffern treffen: %', r; END IF;
  RAISE NOTICE 'PASS (5) Aufloesung exakt + letzte 4 Stellen (nur maskiert) + unbekannt';

  -- (6)
  v_rp1 := finance.fn_add_recurring_payment(v_a, 3000, 'Gehalt', 1::smallint, 'month'::finance.schedule_unit, NULL,
                                            CURRENT_DATE, CURRENT_DATE, NULL, NULL, NULL);
  v_rp2 := finance.fn_add_recurring_payment(v_a, 500, 'Bonus', 1::smallint, 'year'::finance.schedule_unit, NULL,
                                            CURRENT_DATE, CURRENT_DATE, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
  VALUES (v_rp1, 'counterparty_iban', 'DE89370400440532013000', 'statement'),
         (v_rp2, 'counterparty_iban', 'DE89370400440532013000', 'statement'),
         (v_rp1, 'sepa_mandate', 'DE98ZZZ09999999999|M-1', 'statement');
  BEGIN
    INSERT INTO finance.recurring_payment_keys (recurring_payment_id, key_type, key_value, source)
    VALUES (v_rp2, 'sepa_mandate', 'DE98ZZZ09999999999|M-1', 'statement');
    RAISE EXCEPTION 'FAIL (6): SEPA-Mandat doppelt akzeptiert';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  RAISE NOTICE 'PASS (6) Gegen-IBAN je rp, SEPA-Mandat global eindeutig';
END $$;

-- (7) Import erkennt schon vergebene IBAN
DO $$
DECLARE v_res JSONB;
BEGIN
  PERFORM finance.fn_create_account('{"name":"__t_ani_imp__","account_type":"cash","currency":"EUR","account_number":"DE44500105175407324931"}'::jsonb);
  v_res := finance.fn_import_stage(jsonb_build_object('source', 'vision', 'rows', jsonb_build_array(
    jsonb_build_object('entity_type','account','name','Girokonto 4931','account_type','cash',
                       'account_number','DE44 5001 0517 5407 3249 31','opening_balance',100))));
  IF (v_res->>'invalid')::int <> 1 OR (v_res->'errors'->0->>'error') NOT LIKE '%__t_ani_imp__%' THEN
    RAISE EXCEPTION 'FAIL (7) Import-Dublette per IBAN: %', v_res; END IF;
  RAISE NOTICE 'PASS (7) Import: IBAN schon vergeben -> Zeilenfehler nennt das bestehende Konto';
END $$;

ROLLBACK;
