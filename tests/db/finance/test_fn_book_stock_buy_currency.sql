-- tests/db/finance/test_fn_book_stock_buy_currency.sql
-- Kauf in abweichender Kurswaehrung: die DB lehnt ab und fragt nach dem abgebuchten Betrag, nie ein geschaetzter Kurs.
-- cost_basis_total beim echten Kauf = abgebuchter Gesamtbetrag inkl. Gebuehr. Werte erfunden.
BEGIN;
DO $$
DECLARE
  v_settle int; v_depot int; r jsonb; v_w jsonb; v_h int; v_txt text; v_n int;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__fx_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__fx_depot__','account_type','stocks_depot',
                 'currency','EUR','settlement_id',v_settle))->>'account_id')::int;

  -- (1) genannte Fremdwaehrung: Ablehnung, nichts geschrieben
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','5','price_per_share','293','order_fee','0','quote_currency','USD'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_mismatch'
     OR r->>'price_currency' IS DISTINCT FROM 'USD' OR r->>'settlement_currency' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [1 genannte Fremdwaehrung]: %', r; END IF;
  SELECT count(*) INTO v_n FROM finance.depot_holdings WHERE account_id = v_depot;
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL [1 Holding angelegt]'; END IF;
  RAISE NOTICE 'PASS [1 Fremdwaehrung abgelehnt, kein Write]';

  -- (2) ohne genannte Waehrung, das Papier notiert nur in USD (listing_currency aus der Kurs-Pruefung): Ablehnung
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','5','price_per_share','293','listing_currency','USD'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_mismatch' OR r->>'price_currency' IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [2 Notierung ohne Angabe]: %', r; END IF;
  RAISE NOTICE 'PASS [2 ohne Angabe, Notierung USD abgelehnt]';

  -- (2b) ohne genannte Waehrung und ohne bekannte Notierung (auch Yahoo-Ausfall): ablehnen, nicht 1:1 buchen
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','5','price_per_share','293'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_missing' THEN
    RAISE EXCEPTION 'FAIL [2b Waehrung unbekannt]: %', r; END IF;
  RAISE NOTICE 'PASS [2b Waehrung unbekannt abgelehnt]';

  -- (3) abgebuchter Betrag inkl. Gebuehr: Buchung trifft ihn, Kurs abgeleitet, Markt-Waehrung aus der Notierung
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','5','order_fee','1','cost_basis_total','1.254,30','listing_currency','USD'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'settlement_change')::numeric IS DISTINCT FROM -1254.30
     OR (r->'effective'->>'price_per_share')::numeric IS DISTINCT FROM 250.66
     OR (r->'effective'->>'total_debited')::numeric IS DISTINCT FROM 1254.30 THEN
    RAISE EXCEPTION 'FAIL [3 abgebuchter Betrag]: %', r; END IF;
  SELECT quote_currency, id INTO v_txt, v_h FROM finance.depot_holdings WHERE account_id = v_depot;
  IF v_txt IS DISTINCT FROM 'USD' THEN RAISE EXCEPTION 'FAIL [3 quote_currency]: %', v_txt; END IF;
  IF (SELECT description FROM finance.transactions WHERE id = (r->>'buy_tx_id')::int) IS NULL THEN
    RAISE EXCEPTION 'FAIL [3 description NULL]'; END IF;
  RAISE NOTICE 'PASS [3 abgebuchter Betrag, Kurs abgeleitet, Notierung gespeichert]';

  -- (4) Nachkauf ohne Waehrung einer gespeicherten USD-Position: Ablehnung; ausdruecklich EUR: ok
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','1','price_per_share','293'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_mismatch' THEN
    RAISE EXCEPTION 'FAIL [4a Nachkauf USD-Position]: %', r; END IF;
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','1','price_per_share','251','quote_currency','EUR'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'settlement_change')::numeric IS DISTINCT FROM -251 THEN
    RAISE EXCEPTION 'FAIL [4b ausdruecklich EUR]: %', r; END IF;
  RAISE NOTICE 'PASS [4 Nachkauf: gespeicherte Notierung greift, genannte Kontowaehrung geht vor]';

  -- (5) Probelauf -> Write mit beiden Feldern (params || effective), Gebuehr > 0: gleicher Betrag
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983',
         'symbol','IWDA','shares','3','order_fee','2','cost_basis_total','302'));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [5a Probelauf]: %', r; END IF;
  v_w := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983',
         'symbol','IWDA','shares','3','order_fee','2','cost_basis_total','302','price_per_share',r->'effective'->>'price_per_share'));
  IF (v_w->>'ok')::boolean IS NOT TRUE OR (v_w->>'settlement_change')::numeric IS DISTINCT FROM -302 THEN
    RAISE EXCEPTION 'FAIL [5b Write mit beiden Feldern]: %', v_w; END IF;
  RAISE NOTICE 'PASS [5 Probelauf und Write gleich]';

  -- (6) abweichender Kurs neben dem Betrag; Betrag nicht ueber der Gebuehr
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983',
         'symbol','IWDA','shares','3','cost_basis_total','300','price_per_share','99'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6a Kurs und Betrag widersprechen sich]: %', r; END IF;
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983',
         'symbol','IWDA','shares','3','order_fee','5','cost_basis_total','5'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6b Betrag <= Gebuehr]: %', r; END IF;
  RAISE NOTICE 'PASS [6 widerspruechliche Angaben abgelehnt]';

  -- (7) sehr viele Einheiten: der Betrag kommt direkt aus der Abbuchung, nicht aus dem gerundeten Kurs
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B3RBWM25',
         'symbol','VWRL','shares','3000000','cost_basis_total','100'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'settlement_change')::numeric IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL [7 Cent-genau]: %', r; END IF;
  RAISE NOTICE 'PASS [7 Betrag cent-genau]';

  -- (7b) Abbuchungsbetrag mit genannter Kurswaehrung: die Position traegt sie nicht (Kurs-Pruefung lief in Kontowaehrung)
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B5BMR087',
         'symbol','CSPX','shares','2','cost_basis_total','900','quote_currency','USD'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (SELECT quote_currency FROM finance.depot_holdings WHERE id = (r->>'holding_id')::int) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [7b quote bei Abbuchungsbetrag]: %', r; END IF;
  RAISE NOTICE 'PASS [7b]';

  -- (8) Bestandsuebernahme: quote_currency ist die Markt-Notierung einer Euro-Position, kein Guard
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US5949181045',
         'symbol','MSFT','shares','2','price_per_share','300','quote_currency','USD','existing_position',true));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [8 Uebernahme]: %', r; END IF;
  RAISE NOTICE 'PASS [8 Uebernahme ohne Guard]';

  -- (9) Kontoauszug/Broker-Datei: Kurs ist belegt in Kontowaehrung, auch bei USD-Position
  r := finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
         'symbol','AAPL','shares','1','price_per_share','250','price_currency_confirmed',true));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [9 Auszug]: %', r; END IF;
  RAISE NOTICE 'PASS [9 Auszug-Buchung ohne Guard]';
END $$;
ROLLBACK;

-- create_account-Karte liest die Waehrung aus der Rueckgabe: Depot ohne Angabe erbt die Waehrung des Verrechnungskontos
BEGIN;
DO $$
DECLARE v_s int; r jsonb;
BEGIN
  v_s := (finance.fn_create_account('{"name":"__fx_usd_giro__","account_type":"cash","currency":"USD"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_account(jsonb_build_object('name','__fx_usd_depot__','account_type','stocks_depot','settlement_id',v_s));
  IF (r->>'ok')::boolean IS NOT TRUE OR r->>'currency' IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [Karte: Depot erbt USD]: %', r; END IF;
  RAISE NOTICE 'PASS [Karte: Rueckgabe nennt die geerbte Waehrung]';
END $$;
ROLLBACK;
