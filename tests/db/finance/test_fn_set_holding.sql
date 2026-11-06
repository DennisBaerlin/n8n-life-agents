-- tests/db/finance/test_fn_set_holding.sql
-- Testet fn_set_holding: Metadaten-Update (shares/avg unberuehrt), Dubletten-Identitaet -> {ok:false}
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_cash INT; v_depot INT; v_hid1 INT; v_hid2 INT;
  v_name TEXT; v_symbol TEXT; v_shares NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_sh_cash__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_cash := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_sh_depot__','account_type','stocks_depot','account_holder','Test','settlement_id',v_cash)) INTO v_res;
  v_depot := (v_res->>'account_id')::int;

  -- Holdings direkt anlegen (shares bleiben 0 -> ohne Buchung; Test prueft nur Metadaten)
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00BK5BQT80', 'VWCE', 'Vanguard FTSE') RETURNING id INTO v_hid1;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00B4L5Y983', 'IWDA', 'iShares Core') RETURNING id INTO v_hid2;

  -- TEST 1: Name + Symbol von Holding 1 aendern (shares unberuehrt)
  SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid1, 'name', 'Vanguard FTSE All-World', 'symbol', 'VWRL')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL set_holding [ok]: %', v_res; END IF;
  SELECT name, symbol, shares INTO v_name, v_symbol, v_shares FROM finance.depot_holdings WHERE id = v_hid1;
  IF v_name IS DISTINCT FROM 'Vanguard FTSE All-World' OR v_symbol IS DISTINCT FROM 'VWRL' THEN
    RAISE EXCEPTION 'FAIL set_holding [metadata]: name=% symbol=%', v_name, v_symbol; END IF;
  IF v_shares IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL set_holding [shares unberuehrt]: erwartet 0, got %', v_shares; END IF;
  RAISE NOTICE 'PASS set_holding [Metadaten geaendert, shares unberuehrt]';

  -- TEST 2: ISIN von Holding 2 auf die ISIN von Holding 1 setzen -> UNIQUE-Verletzung -> {ok:false}
  SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid2, 'isin', 'IE00BK5BQT80')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL set_holding [dup]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS set_holding [Dubletten-ISIN -> ok:false]';

  -- TEST 3: not-found -> RAISE
  BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', 99999999, 'name', 'X')) INTO v_res;
    RAISE EXCEPTION 'FAIL set_holding [not_found]: haette RAISE werfen muessen';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' THEN RAISE NOTICE 'PASS set_holding [not_found]';
    ELSE RAISE EXCEPTION 'FAIL set_holding [not_found]: falscher Fehler: %', SQLERRM; END IF;
  END;

  -- TEST 4 (WS2b): asset_class partielles Update -> Tag gesetzt, name/symbol UNVERAENDERT (Korrektur des Auto-Tags)
  DECLARE v_tag TEXT; v_name4 TEXT; BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid1, 'asset_class', 'sp500')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL set_holding [asset_class ok]: %', v_res; END IF;
    SELECT asset_class, name INTO v_tag, v_name4 FROM finance.depot_holdings WHERE id = v_hid1;
    IF v_tag IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL set_holding [asset_class set]: erwartet sp500, got %', v_tag; END IF;
    IF v_name4 IS DISTINCT FROM 'Vanguard FTSE All-World' THEN
      RAISE EXCEPTION 'FAIL set_holding [asset_class partiell]: name darf nicht geaendert sein, got %', v_name4; END IF;
    RAISE NOTICE 'PASS set_holding [asset_class partielles Update, name unberuehrt]';
  END;

  -- TEST 5 (WS2b): ungueltiges asset_class-Format -> {ok:false} (kein CHECK-RAISE/Owner-Alert), Tag unveraendert
  DECLARE v_tag5 TEXT; BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid1, 'asset_class', 'S&P 500')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL set_holding [asset_class bad format]: erwartet ok=false, got %', v_res; END IF;
    SELECT asset_class INTO v_tag5 FROM finance.depot_holdings WHERE id = v_hid1;
    IF v_tag5 IS DISTINCT FROM 'sp500' THEN
      RAISE EXCEPTION 'FAIL set_holding [bad format darf Tag nicht aendern]: got %', v_tag5; END IF;
    RAISE NOTICE 'PASS set_holding [ungueltiges asset_class-Format -> ok:false, Tag unveraendert]';
  END;

  -- TEST 6 (WS2b): Format-CHECK ist der strukturelle Backstop (Direktzugriff unter Umgehung der fn)
  BEGIN
    UPDATE finance.depot_holdings SET asset_class = 'bad tag!' WHERE id = v_hid1;
    RAISE EXCEPTION 'FAIL set_holding [CHECK backstop]: ungueltiger Tag wurde direkt akzeptiert';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS set_holding [asset_class Format-CHECK Backstop greift]';
  END;

  -- TEST 7 (Phase M): provider_symbol + quote_currency partielles Update -> gesetzt, symbol/name UNVERAENDERT.
  DECLARE v_ps TEXT; v_qc CHAR(3); v_sym7 TEXT; BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid2, 'provider_symbol', 'IWDA.UK', 'quote_currency', 'USD')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL set_holding [provider_symbol ok]: %', v_res; END IF;
    SELECT provider_symbol, quote_currency, symbol INTO v_ps, v_qc, v_sym7 FROM finance.depot_holdings WHERE id = v_hid2;
    IF v_ps IS DISTINCT FROM 'IWDA.UK' OR v_qc IS DISTINCT FROM 'USD' THEN
      RAISE EXCEPTION 'FAIL set_holding [provider/quote set]: provider_symbol=% quote_currency=%', v_ps, v_qc; END IF;
    IF v_sym7 IS DISTINCT FROM 'IWDA' THEN
      RAISE EXCEPTION 'FAIL set_holding [provider partiell]: symbol darf nicht geaendert sein, got %', v_sym7; END IF;
    RAISE NOTICE 'PASS set_holding [provider_symbol + quote_currency partielles Update, symbol unberuehrt]';
  END;

  -- TEST 8 (WP-1 Crash-Schutz): currency + quote_currency in KLEINSCHREIBUNG -> normalisiert gespeichert
  -- (VOR dem Fix: {ok:false}-Ablehnung bei lowercase; zudem schrieb die UPDATE-Site den Roh-Wert).
  DECLARE v_cc8 CHAR(3); v_qc8 CHAR(3); BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid2, 'currency', 'jpy', 'quote_currency', 'gbp')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL set_holding [lowercase currency/quote]: erwartet ok=true (normalisiert), got %', v_res; END IF;
    SELECT currency, quote_currency INTO v_cc8, v_qc8 FROM finance.depot_holdings WHERE id = v_hid2;
    IF v_cc8 IS DISTINCT FROM 'JPY' OR v_qc8 IS DISTINCT FROM 'GBP' THEN
      RAISE EXCEPTION 'FAIL set_holding [normalisiert schreiben]: erwartet currency=JPY quote=GBP, got currency=% quote=%', v_cc8, v_qc8; END IF;
    RAISE NOTICE 'PASS set_holding [lowercase currency jpy->JPY + quote gbp->GBP normalisiert gespeichert]';
  END;

  -- TEST 8b (WP-1): echt-ungueltiger Code ('DOLLAR') -> {ok:false}, Wert unveraendert (kein RAISE/Owner-Alert).
  DECLARE v_qc8b CHAR(3); BEGIN
    SELECT finance.fn_set_holding(jsonb_build_object('holding_id', v_hid2, 'quote_currency', 'DOLLAR')) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL set_holding [quote_currency bad]: erwartet ok=false, got %', v_res; END IF;
    SELECT quote_currency INTO v_qc8b FROM finance.depot_holdings WHERE id = v_hid2;
    IF v_qc8b IS DISTINCT FROM 'GBP' THEN
      RAISE EXCEPTION 'FAIL set_holding [bad quote_currency darf Wert nicht aendern]: got %', v_qc8b; END IF;
    RAISE NOTICE 'PASS set_holding [ungueltige quote_currency DOLLAR -> ok:false, Wert unveraendert]';
  END;
END $$;

ROLLBACK;
