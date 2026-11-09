-- tests/db/finance/test_fn_book_stock_sell_currency.sql
-- Verkauf in abweichender oder unbekannter Kurswaehrung: die DB lehnt ab und fragt nach dem gutgeschriebenen Betrag, nie ein
-- geschaetzter Kurs. total_credited = Gutschrift nach Gebuehr in Kontowaehrung. Werte erfunden.
BEGIN;
DO $$
DECLARE
  v_settle int; v_depot int; v_h int; v_u int; r jsonb; v_w jsonb; v_shares numeric; v_bal numeric;
BEGIN
  v_settle := (finance.fn_create_account('{"name":"__fxs_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__fxs_depot__','account_type','stocks_depot',
                 'currency','EUR','settlement_id',v_settle))->>'account_id')::int;
  v_h := (finance.fn_book_stock_buy(jsonb_build_object('price_currency_confirmed',true,'depot_id',v_depot,'settlement_id',v_settle,
          'isin','IE00B4L5Y983','symbol','IWDA','shares','20','price_per_share','100'))->>'holding_id')::int;
  v_u := (finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','US0378331005',
          'symbol','AAPL','shares','5','cost_basis_total','1000','listing_currency','USD'))->>'holding_id')::int;
  SELECT shares INTO v_shares FROM finance.depot_holdings WHERE id = v_h;
  SELECT balance INTO v_bal FROM finance.account_balances WHERE account_id = v_settle;

  -- (1) genannte Fremdwaehrung: Ablehnung, nichts geschrieben
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','5','price_per_share','300','quote_currency','USD'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_mismatch'
     OR r->>'price_currency' IS DISTINCT FROM 'USD' OR r->>'settlement_currency' IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL [1 genannte Fremdwaehrung]: %', r; END IF;
  IF (SELECT shares FROM finance.depot_holdings WHERE id = v_h) IS DISTINCT FROM v_shares
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_settle) IS DISTINCT FROM v_bal THEN
    RAISE EXCEPTION 'FAIL [1 geschrieben]'; END IF;
  RAISE NOTICE 'PASS [1 Fremdwaehrung abgelehnt, kein Write]';

  -- (2) keine Waehrung genannt, Position ohne Notierung: unbekannt, Ablehnung
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','5','price_per_share','300'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_missing' THEN
    RAISE EXCEPTION 'FAIL [2 Waehrung unbekannt]: %', r; END IF;
  RAISE NOTICE 'PASS [2 Waehrung unbekannt abgelehnt]';

  -- (3) keine Waehrung genannt, Position notiert in USD: Ablehnung; ausdruecklich EUR: ok
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_u,'symbol','AAPL','shares','1','price_per_share','300'));
  IF (r->>'ok')::boolean OR r->>'code' IS DISTINCT FROM 'price_currency_mismatch' OR r->>'price_currency' IS DISTINCT FROM 'USD' THEN
    RAISE EXCEPTION 'FAIL [3a USD-Position]: %', r; END IF;
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_u,'symbol','AAPL','shares','1','price_per_share','260','quote_currency','EUR'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'proceeds')::numeric IS DISTINCT FROM 260 THEN
    RAISE EXCEPTION 'FAIL [3b genannt EUR]: %', r; END IF;
  RAISE NOTICE 'PASS [3 gespeicherte Notierung greift, genannte Kontowaehrung geht vor]';

  -- (4) Gutschrift nach Gebuehr: Buchung trifft sie, Kurs abgeleitet (900 + 1) / 2 = 450,50
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','2','order_fee','1','total_credited','900,00'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (r->>'proceeds')::numeric IS DISTINCT FROM 900
     OR (r->'effective'->>'price_per_share')::numeric IS DISTINCT FROM 450.5 THEN
    RAISE EXCEPTION 'FAIL [4 Gutschrift]: %', r; END IF;
  IF (SELECT description FROM finance.transactions WHERE id = (r->>'sell_tx_id')::int) IS NULL THEN
    RAISE EXCEPTION 'FAIL [4 description NULL]'; END IF;
  RAISE NOTICE 'PASS [4 Gutschrift, Kurs abgeleitet]';

  -- (5) Probelauf -> Write mit beiden Feldern (params || effective): gleicher Betrag, auch bei genannter Fremdwaehrung
  v_w := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','3','order_fee','2',
          'total_credited','300','price_per_share',r->'effective'->>'price_per_share','quote_currency','USD'));
  IF (v_w->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [5a Betrag und Kurs widersprechen sich]: %', v_w; END IF;
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','3','order_fee','2','total_credited','298','quote_currency','USD'));
  v_w := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','3','order_fee','2','total_credited','298',
          'quote_currency','USD','price_per_share',r->'effective'->>'price_per_share'));
  IF (r->>'ok')::boolean IS NOT TRUE OR (v_w->>'ok')::boolean IS NOT TRUE OR (v_w->>'proceeds')::numeric IS DISTINCT FROM 298 THEN
    RAISE EXCEPTION 'FAIL [5b Write mit beiden Feldern]: % / %', r, v_w; END IF;
  RAISE NOTICE 'PASS [5 Probelauf und Write gleich]';

  -- (6) Gutschrift nicht positiv oder unlesbar
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','1','total_credited','0'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6a Gutschrift 0]: %', r; END IF;
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_h,'symbol','IWDA','shares','1','total_credited','etwa hundert'));
  IF (r->>'ok')::boolean IS NOT FALSE THEN RAISE EXCEPTION 'FAIL [6b Gutschrift unlesbar]: %', r; END IF;
  RAISE NOTICE 'PASS [6 Gutschrift geprueft]';

  -- (7) Kontoauszug/Broker-Datei: Kurs belegt in Kontowaehrung, auch bei USD-Position
  r := finance.fn_book_stock_sell(jsonb_build_object('settlement_id',v_settle,'holding_id',v_u,'symbol','AAPL','shares','1','price_per_share','250','price_currency_confirmed',true));
  IF (r->>'ok')::boolean IS NOT TRUE THEN RAISE EXCEPTION 'FAIL [7 Auszug]: %', r; END IF;
  RAISE NOTICE 'PASS [7 Auszug-Buchung ohne Guard]';
END $$;
ROLLBACK;
