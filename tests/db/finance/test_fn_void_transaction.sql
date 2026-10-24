-- tests/db/finance/test_fn_void_transaction.sql
-- Testet fn_void_transaction: einfache Tx, Depot-Buy (Holding bleibt, shares 0), Oversell-Guard,
-- Kredit-Paar (beide Beine), not-found
BEGIN;
-- Audit Paket 3: ein Sparziel braucht ein Sparkonto -> Fixture-Topf fuer fn_create_savings_goal.
INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__sg_fixture_pot__','cash','EUR','active');

DO $$
DECLARE
  v_res JSONB; v_cash INT; v_settle INT; v_depot INT; v_hid INT;
  v_txid INT; v_bal NUMERIC; v_shares NUMERIC; v_exists BOOLEAN;
  v_giro INT; v_loan INT; v_loanacc INT; v_loantx INT; v_remaining INT;
BEGIN
  -- ===== TEST 1: einfache Cash-Buchung voiden -> Saldo zurueck auf 0 =====
  SELECT finance.fn_create_account('{"name":"__test_void_cash__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_cash := (v_res->>'account_id')::int;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_cash, 1000, CURRENT_DATE, 'other', 'Testeinlage') RETURNING id INTO v_txid;
  SELECT finance.fn_get_balance(v_cash) INTO v_bal;
  IF v_bal IS DISTINCT FROM 1000 THEN RAISE EXCEPTION 'FAIL void [setup]: balance % (erwartet 1000)', v_bal; END IF;

  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_txid)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'deleted_count')::int IS DISTINCT FROM 1 THEN
    RAISE EXCEPTION 'FAIL void [cash]: %', v_res; END IF;
  SELECT finance.fn_get_balance(v_cash) INTO v_bal;
  IF v_bal IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL void [cash balance]: % (erwartet 0)', v_bal; END IF;
  -- Void-Audit: geloeschtes Payload muss festgehalten sein.
  IF NOT EXISTS (
    SELECT 1 FROM finance.transaction_audit
    WHERE transaction_id = v_txid AND (payload->>'amount')::numeric = 1000
  ) THEN RAISE EXCEPTION 'FAIL void [audit]: kein Audit-Eintrag fuer gevoidete Tx %', v_txid; END IF;
  RAISE NOTICE 'PASS void [Cash-Buchung geloescht, Saldo 0, Audit-Eintrag vorhanden]';

  -- ===== TEST 2: Depot-Kauf voiden -> Holding bleibt (shares 0), ISIN NICHT geloescht =====
  SELECT finance.fn_create_account('{"name":"__test_void_settle__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_settle := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_void_depot__','account_type','stocks_depot','account_holder','Test','settlement_id',v_settle)) INTO v_res;
  v_depot := (v_res->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00BK5BQT80', 'VWCE', 'Vanguard') RETURNING id INTO v_hid;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description)
  VALUES (v_settle, -1101, CURRENT_DATE, 'buy', v_hid, 10, 1, 'Kauf VWCE') RETURNING id INTO v_txid;
  SELECT shares INTO v_shares FROM finance.depot_holdings WHERE id = v_hid;
  IF v_shares IS DISTINCT FROM 10 THEN RAISE EXCEPTION 'FAIL void [setup buy]: shares % (erwartet 10)', v_shares; END IF;

  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_txid)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void [buy]: %', v_res; END IF;
  SELECT EXISTS(SELECT 1 FROM finance.depot_holdings WHERE id = v_hid), shares
    INTO v_exists, v_shares FROM finance.depot_holdings WHERE id = v_hid;
  IF v_exists IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void [holding geloescht!]: Holding-Zeile darf NICHT verschwinden'; END IF;
  IF v_shares IS DISTINCT FROM 0 THEN RAISE EXCEPTION 'FAIL void [shares]: % (erwartet 0)', v_shares; END IF;
  RAISE NOTICE 'PASS void [Depot-Kauf geloescht, Holding bleibt mit shares=0 (ISIN erhalten)]';

  -- ===== TEST 3: Oversell-Guard -- Kauf voiden, auf den ein spaeterer Verkauf aufbaut =====
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description)
  VALUES (v_settle, -1101, CURRENT_DATE, 'buy', v_hid, 10, 1, 'Kauf VWCE 2') RETURNING id INTO v_txid;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, holding_id, shares, order_fee, description)
  VALUES (v_settle, 573, CURRENT_DATE, 'sell', v_hid, -5, 2, 'Verkauf VWCE');
  -- shares jetzt 5; den Kauf (10) voiden -> 5 - 10 = -5 -> {ok:false}
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_txid)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL void [oversell-guard]: erwartet ok=false, got %', v_res; END IF;
  RAISE NOTICE 'PASS void [Oversell-Guard: Kauf mit abhaengigem Verkauf -> ok:false]';

  -- ===== TEST 4: Kredit-Event paarweise -> beide Beine geloescht =====
  SELECT finance.fn_create_account('{"name":"__test_void_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_loan(jsonb_build_object(
    'name','__test_void_loan__','lender','ING','borrower','Erika','original_amount',100000,
    'disbursement_date',CURRENT_DATE::text,'interest_rate',3.0,'principal_rate',2.0,'monthly_annuity',1200,
    'schedule_day_of_month',1,'first_payment_date',(CURRENT_DATE + 30)::text,   -- Rate => erstes Ratendatum Pflicht
    'debit_account_id',v_giro,'disbursement_account_id',v_giro
  )) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_loanacc := (v_res->>'loan_account_id')::int;
  -- Zwei disbursement-Beine (Kreditkonto + Giro), beide loan_id + selbes Datum.
  SELECT count(*)::int INTO v_remaining FROM finance.transactions WHERE loan_id = v_loan;
  IF v_remaining < 2 THEN RAISE EXCEPTION 'FAIL void [setup loan]: erwartet >=2 Beine, got %', v_remaining; END IF;
  SELECT id INTO v_loantx FROM finance.transactions WHERE loan_id = v_loan ORDER BY id LIMIT 1;

  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_loantx)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void [loan]: %', v_res; END IF;
  SELECT count(*)::int INTO v_remaining FROM finance.transactions WHERE loan_id = v_loan;
  IF v_remaining IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL void [loan-paar]: nach Void noch % Kredit-Beine (erwartet 0 -> beide geloescht)', v_remaining; END IF;
  RAISE NOTICE 'PASS void [Kredit-Event: beide Beine zusammen geloescht]';

  -- ===== TEST 4b: Transfer -> beide Beine via group_id zusammen geloescht =====
  DECLARE
    v_ta INT; v_tb INT; v_debit_tx INT; v_grp_remaining INT; v_bala NUMERIC; v_balb NUMERIC;
  BEGIN
    SELECT finance.fn_create_account('{"name":"__test_void_ta__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
    v_ta := (v_res->>'account_id')::int;
    SELECT finance.fn_create_account('{"name":"__test_void_tb__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
    v_tb := (v_res->>'account_id')::int;
    SELECT finance.fn_book_transfer(jsonb_build_object(
      'from_account_id', v_ta, 'to_account_id', v_tb, 'amount', 50, 'transaction_date', CURRENT_DATE::text,
      'from_account_name', '__test_void_ta__', 'to_account_name', '__test_void_tb__')) INTO v_res;
    v_debit_tx := (v_res->>'debit_tx_id')::int;
    -- Beide Beine teilen eine group_id -> Void EINES Beins entfernt BEIDE.
    SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_debit_tx)) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'deleted_count')::int IS DISTINCT FROM 2 THEN
      RAISE EXCEPTION 'FAIL void [transfer-group]: erwartet ok=true deleted_count=2, got %', v_res; END IF;
    SELECT count(*)::int INTO v_grp_remaining FROM finance.transactions WHERE account_id IN (v_ta, v_tb);
    SELECT finance.fn_get_balance(v_ta), finance.fn_get_balance(v_tb) INTO v_bala, v_balb;
    IF v_grp_remaining IS DISTINCT FROM 0 OR v_bala IS DISTINCT FROM 0 OR v_balb IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'FAIL void [transfer-group]: remaining=% balA=% balB=% (erwartet 0/0/0)', v_grp_remaining, v_bala, v_balb; END IF;
    RAISE NOTICE 'PASS void [Transfer: beide Beine via group_id geloescht, Salden 0]';
  END;

  -- ===== TEST 5: not-found -> RAISE =====
  BEGIN
    SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', 99999999)) INTO v_res;
    RAISE EXCEPTION 'FAIL void [not_found]: haette RAISE werfen muessen';
  EXCEPTION WHEN others THEN
    IF SQLERRM LIKE '%not found%' THEN RAISE NOTICE 'PASS void [not_found]';
    ELSE RAISE EXCEPTION 'FAIL void [not_found]: falscher Fehler: %', SQLERRM; END IF;
  END;
END $$;

-- TEST 6-9 (Audit F4/F5): Void raeumt abgeleiteten Zustand mit auf.
DO $$
DECLARE
  v_res     JSONB;
  v_settle  INT;
  v_depot   INT;
  v_goal    INT;
  v_plan_rp INT;
  v_buy     INT;
  v_cur     NUMERIC;
  v_cnt     INT;
  v_delta   NUMERIC;
  v_giro    INT;
  v_loan    INT;
  v_loan_rp INT;
  v_tx      INT;
  v_status  TEXT;
  v_rp_st   TEXT;
  v_rp_to   DATE;
  v_re      INT;
BEGIN
  -- Setup Sparziel + goal-verknuepfter Sparplan (Muster test_fn_book_stock_buy TEST 10)
  SELECT finance.fn_create_account('{"name":"__test_vd_settle__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb) INTO v_res;
  v_settle := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_vd_depot__','account_type','stocks_depot',
    'account_holder','Test','currency','EUR','settlement_id',v_settle)) INTO v_res;
  v_depot := (v_res->>'account_id')::int;
  SELECT finance.fn_create_savings_goal(jsonb_build_object('name','__test_vd_goal__','target_amount',5000,
    'target_date',(CURRENT_DATE + 365)::text,'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__sg_fixture_pot__'),'account_id',v_settle,'schedule_day_of_month',1,
    'first_payment_date',(CURRENT_DATE + 5)::text)) INTO v_res;
  v_goal := (v_res->>'goal_id')::int;
  SELECT finance.fn_create_savings_plan(jsonb_build_object('name','__test_vd_plan__','depot_name','__test_vd_depot__',
    'isin','IE00B4L5Y983','symbol','IUSQ','security_name','iShares MSCI World','amount',50,'schedule_interval',1,
    'schedule_unit','month','first_payment_date',CURRENT_DATE::text)) INTO v_res;
  v_plan_rp := (v_res->>'recurring_payment_id')::int;
  PERFORM finance.fn_set_savings_goal(jsonb_build_object('goal_id',v_goal,'link_savings_plan_name','__test_vd_plan__'));
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id)
  VALUES (v_settle, 200, CURRENT_DATE, 'other', v_goal);

  -- ===== TEST 6: Void eines goal-verknuepften Sparplan-Kaufs -> Sparziel bleibt 200 (vorher 250) =====
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B4L5Y983','symbol','IUSQ','name','iShares MSCI World','shares',0.5,'price_per_share',100,
    'order_fee',0,'transaction_date',CURRENT_DATE::text,'recurring_payment_id',v_plan_rp)) INTO v_res;
  v_buy := (v_res->>'buy_tx_id')::int;
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_buy)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void [goal-buy]: %', v_res; END IF;
  SELECT current_amount INTO v_cur FROM finance.savings_goal_progress WHERE id = v_goal;
  IF v_cur IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL void [goal-buy]: Sparziel erwartet 200, got % (Journal-Zeile ueberlebt?)', v_cur; END IF;
  -- append-only: die Kauf-Zeile bleibt, eine Gegenzeile kind=void -50 kommt dazu
  SELECT count(*), sum(delta_native) FILTER (WHERE kind = 'void') INTO v_cnt, v_delta
  FROM finance.savings_goal_reserve_entries WHERE savings_goal_id = v_goal;
  IF v_cnt IS DISTINCT FROM 2 OR v_delta IS DISTINCT FROM -50 THEN
    RAISE EXCEPTION 'FAIL void [goal-buy journal]: erwartet 2 Zeilen inkl. void -50, got count=% void=%', v_cnt, v_delta; END IF;
  RAISE NOTICE 'PASS void [goal-buy: Sparziel 200, Journal-Gegenzeile void -50]';

  -- ===== TEST 6b: Reserve schon freigegeben -> Void wuerde Ziel-Reserve negativ machen -> ok:false =====
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,
    'isin','IE00B4L5Y983','symbol','IUSQ','name','iShares MSCI World','shares',0.5,'price_per_share',100,
    'order_fee',0,'transaction_date',(CURRENT_DATE + 1)::text,'recurring_payment_id',v_plan_rp)) INTO v_res;
  v_buy := (v_res->>'buy_tx_id')::int;
  -- Freigabe simulieren: Depot-Reserve des Ziels auf 0 (manual -50)
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind)
  VALUES (v_goal, v_depot, -50, 'EUR', 'manual');
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_buy)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL void [goal-buy freigegeben]: erwartet ok=false, got %', v_res; END IF;
  IF NOT EXISTS (SELECT 1 FROM finance.transactions WHERE id = v_buy) THEN
    RAISE EXCEPTION 'FAIL void [goal-buy freigegeben]: Kauf trotz ok:false geloescht'; END IF;
  RAISE NOTICE 'PASS void [goal-buy mit freigegebener Reserve -> ok:false, nichts geloescht]';

  -- ===== TEST 7: Void einer Abloesung -> Kredit wieder active, Rate laeuft wieder =====
  SELECT finance.fn_create_account('{"name":"__test_vd_giro__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_giro := (v_res->>'account_id')::int;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_vd_kredit__','lender','B','borrower','T',
    'original_amount',10000,'current_balance',10000,'disbursement_date',(CURRENT_DATE - 40)::text,'interest_rate',2,
    'monthly_annuity',500,'first_payment_date',(CURRENT_DATE + 5)::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  SELECT recurring_payment_id INTO v_loan_rp FROM finance.loans WHERE id = v_loan;
  PERFORM finance.fn_settle_loan(jsonb_build_object('loan_name','__test_vd_kredit__','debit_account_id',v_giro,
    'settlement_date',CURRENT_DATE::text));
  SELECT id INTO v_tx FROM finance.transactions WHERE loan_id = v_loan AND category = 'settlement' LIMIT 1;
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL void [settle]: %', v_res; END IF;
  IF (v_res->'reverted_loans'->0->>'loan_id')::int IS DISTINCT FROM v_loan
     OR v_res->'reverted_loans'->0->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL void [settle return]: reverted_loans erwartet [{loan_id:%,status:active}], got %', v_loan, v_res->'reverted_loans'; END IF;
  SELECT status::text INTO v_status FROM finance.loans WHERE id = v_loan;
  SELECT status::text, valid_to INTO v_rp_st, v_rp_to FROM finance.recurring_payments WHERE id = v_loan_rp;
  IF v_status IS DISTINCT FROM 'active' OR v_rp_st IS DISTINCT FROM 'active' OR v_rp_to IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL void [settle]: Kredit=% Rate=%/% (erwartet active/active/NULL)', v_status, v_rp_st, v_rp_to; END IF;
  RAISE NOTICE 'PASS void [Abloesung rueckgaengig -> Kredit active, Rate laeuft wieder]';

  -- ===== TEST 8: Void der Abloesung eines Kredits OHNE Rate -> paused (CHECK active_needs_annuity), kein Fehler =====
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_vd_family__','lender','Oma','borrower','T',
    'original_amount',5000,'current_balance',5000,'disbursement_date',(CURRENT_DATE - 40)::text,'interest_rate',0,
    'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  PERFORM finance.fn_settle_loan(jsonb_build_object('loan_name','__test_vd_family__','debit_account_id',v_giro,
    'settlement_date',CURRENT_DATE::text));
  SELECT id INTO v_tx FROM finance.transactions WHERE loan_id = v_loan AND category = 'settlement' LIMIT 1;
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx)) INTO v_res;
  SELECT status::text INTO v_status FROM finance.loans WHERE id = v_loan;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_status IS DISTINCT FROM 'paused' THEN
    RAISE EXCEPTION 'FAIL void [settle ohne Rate]: ok=% status=% (erwartet true/paused)', v_res->>'ok', v_status; END IF;
  RAISE NOTICE 'PASS void [Abloesung eines Kredits ohne Rate -> paused]';

  -- ===== TEST 8b (Review): Void stellt den Zustand VOR der Abloesung exakt wieder her: ein vorher pausierter
  --   Kredit bleibt pausiert, ein vertragliches Raten-Ende (valid_to) bleibt erhalten =====
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_vd_kredit3__','lender','B','borrower','T',
    'original_amount',8000,'current_balance',8000,'disbursement_date',(CURRENT_DATE - 40)::text,'interest_rate',2,
    'monthly_annuity',400,'first_payment_date',(CURRENT_DATE + 5)::text,'debit_account_id',v_giro)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  SELECT recurring_payment_id INTO v_loan_rp FROM finance.loans WHERE id = v_loan;
  UPDATE finance.loans SET status = 'paused' WHERE id = v_loan;
  UPDATE finance.recurring_payments SET status = 'paused', valid_to = '2030-06-01' WHERE id = v_loan_rp;
  PERFORM finance.fn_settle_loan(jsonb_build_object('loan_name','__test_vd_kredit3__','debit_account_id',v_giro,
    'settlement_date',CURRENT_DATE::text));
  SELECT id INTO v_tx FROM finance.transactions WHERE loan_id = v_loan AND category = 'settlement' LIMIT 1;
  PERFORM finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx));
  SELECT status::text INTO v_status FROM finance.loans WHERE id = v_loan;
  SELECT status::text, valid_to INTO v_rp_st, v_rp_to FROM finance.recurring_payments WHERE id = v_loan_rp;
  IF v_status IS DISTINCT FROM 'paused' OR v_rp_st IS DISTINCT FROM 'paused' OR v_rp_to IS DISTINCT FROM DATE '2030-06-01' THEN
    RAISE EXCEPTION 'FAIL void [settle exakt]: Kredit=% Rate=%/% (erwartet paused/paused/2030-06-01)', v_status, v_rp_st, v_rp_to; END IF;
  RAISE NOTICE 'PASS void [Abloesung rueckgaengig stellt pausiert + Raten-Ende exakt wieder her]';

  -- ===== TEST 9: Void des Verkaufserloeses -> Immobilie wieder active =====
  SELECT (finance.fn_create_real_estate('{"name":"__test_vd_haus__","current_value":300000,"owner":"T"}'::jsonb)->>'real_estate_id')::int INTO v_re;
  SELECT finance.fn_sell_real_estate(jsonb_build_object('real_estate_name','__test_vd_haus__',
    'proceeds_account_id',v_giro,'sale_date',CURRENT_DATE::text,'sale_price','320000')) INTO v_res;
  v_tx := (v_res->>'proceeds_tx_id')::int;
  SELECT finance.fn_void_transaction(jsonb_build_object('transaction_id', v_tx)) INTO v_res;
  SELECT status::text INTO v_status FROM finance.real_estate WHERE id = v_re;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_status IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'FAIL void [Verkauf]: ok=% status=% (erwartet true/active)', v_res->>'ok', v_status; END IF;
  IF (v_res->'reverted_real_estate'->>0)::int IS DISTINCT FROM v_re THEN
    RAISE EXCEPTION 'FAIL void [Verkauf return]: reverted_real_estate erwartet [%], got %', v_re, v_res->'reverted_real_estate'; END IF;
  RAISE NOTICE 'PASS void [Immobilienverkauf rueckgaengig -> active]';
END $$;

ROLLBACK;
