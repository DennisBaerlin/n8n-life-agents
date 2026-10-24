-- tests/db/finance/test_write_guards.sql
-- Import-Haertung 2026-10-22: Werte, die vorher erst an Enum-Cast/CHECK/Trigger scheiterten (RAISE -> Owner-Alert bzw.
-- Rohfehler nach der Import-Freigabe), lehnen die Write-fns jetzt VOR dem ersten Write als {ok:false} ab.
-- Je Fall: ok:false + nichts geschrieben. Dazu die zwei neuen CHECK-Backstops aus V018 (Direkt-Write -> check_violation).
BEGIN;

DO $$
DECLARE
  v_res     JSONB;
  v_cash    INT;
  v_depot   INT;
  v_re      INT;
  v_pen     INT;
  v_loan    INT;
  v_goal    INT;
  v_ok      BOOLEAN;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__wg cash__","account_type":"cash","opening_balance":1000}'::jsonb)->>'account_id')::int
    INTO v_cash;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__wg depot__','account_type','stocks_depot',
    'settlement_id', v_cash))->>'account_id')::int INTO v_depot;

  -- [1] Konto: Typ fehlt/unbekannt, Verrechnungskonto = Depot, Zins-Konditionen ungueltig
  SELECT finance.fn_create_account('{"name":"__wg a1__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 typ fehlt] %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg a1__","account_type":"girokonto"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 typ unbekannt] %', v_res; END IF;
  SELECT finance.fn_create_account(jsonb_build_object('name','__wg a1__','account_type','crypto_depot','settlement_id', v_depot)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 settlement=depot] %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg a1__","account_type":"cash","interest_rate":2,"interest_credit_unit":"month","interest_credit_day_of_month":31}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 zins-tag 31] %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg a1__","account_type":"cash","interest_rate":2,"interest_credit_unit":"month","interest_posting_day_of_month":-1}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 gutschrift -1] %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg a1__","account_type":"cash","interest_rate":2,"interest_credit_unit":"month","interest_day_count_convention":"ACT/366"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 konvention] %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg a1__","account_type":"cash","interest_rate":2,"interest_credit_unit":"monthly"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [1 rhythmus] %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.accounts WHERE name = '__wg a1__') THEN RAISE EXCEPTION 'FAIL [1]: abgelehnt, aber angelegt'; END IF;
  RAISE NOTICE 'PASS [1 Konto: Typ, Verrechnungskonto, Zins-Tag/Gutschrift-Tag/Konvention/Rhythmus -> ok:false ohne Write]';

  -- [2] set_account_interest (via fn_interest_rate_preview): Gutschrift-Tag -1 / Konvention unbekannt
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id', v_cash, 'annual_rate', 2, 'posting_day_of_month', -1)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2 gutschrift -1] %', v_res; END IF;
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id', v_cash, 'annual_rate', 2, 'day_count_convention', 'ACT/ACT')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [2 konvention] %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.account_interest_rates WHERE account_id = v_cash) THEN RAISE EXCEPTION 'FAIL [2]: Zinszeile trotz ok:false'; END IF;
  RAISE NOTICE 'PASS [2 set_account_interest: Gutschrift-Tag -1 / Konvention -> ok:false]';

  -- [3] Rente: unbekannter Typ, Beitrag vom Depot; set_pension: unbekannter Status
  SELECT finance.fn_create_pension('{"name":"__wg pen__","pension_type":"betriebsrente"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3 typ] %', v_res; END IF;
  SELECT finance.fn_create_pension(jsonb_build_object('name','__wg pen__','pension_type','private',
    'contribution_amount', 50, 'debit_account_id', v_depot, 'first_payment_date', '2026-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3 depot] %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.pension WHERE name = '__wg pen__') THEN RAISE EXCEPTION 'FAIL [3]: abgelehnt, aber angelegt'; END IF;
  SELECT (finance.fn_create_pension('{"name":"__wg pen ok__","pension_type":"private"}'::jsonb)->>'pension_id')::int INTO v_pen;
  SELECT finance.fn_set_pension(jsonb_build_object('pension_id', v_pen, 'status', 'ruhend')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [3 status] %', v_res; END IF;
  RAISE NOTICE 'PASS [3 Rente: Typ/Depot-Beitrag/Status -> ok:false]';

  -- [4] Immobilie: unbekannter Status (create + set)
  SELECT finance.fn_create_real_estate('{"name":"__wg re__","current_value":100,"status":"owned"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.real_estate WHERE name = '__wg re__') THEN
    RAISE EXCEPTION 'FAIL [4 create] %', v_res;
  END IF;
  SELECT (finance.fn_create_real_estate('{"name":"__wg re ok__","current_value":100}'::jsonb)->>'real_estate_id')::int INTO v_re;
  SELECT finance.fn_set_real_estate(jsonb_build_object('real_estate_id', v_re, 'status', 'verkauft')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (SELECT status::text FROM finance.real_estate WHERE id = v_re) <> 'active' THEN
    RAISE EXCEPTION 'FAIL [4 set] %', v_res;
  END IF;
  RAISE NOTICE 'PASS [4 Immobilie: unbekannter Status -> ok:false]';

  -- [5] Kredit: Rate vom Depot / set_loan unbekannter Status
  SELECT finance.fn_create_loan(jsonb_build_object('name','__wg loan__','original_amount',1000,'disbursement_date','2026-01-01',
    'interest_rate',3,'principal_rate',2,'monthly_annuity',50,'first_payment_date','2026-02-01','debit_account_id', v_depot)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.loans WHERE name = '__wg loan__') THEN
    RAISE EXCEPTION 'FAIL [5 depot] %', v_res;
  END IF;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__wg loan ok__','original_amount',1000,'disbursement_date','2026-01-01',
    'interest_rate',3,'principal_rate',2,'monthly_annuity',50,'first_payment_date','2026-02-01','debit_account_id', v_cash))->>'loan_id')::int
    INTO v_loan;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'status', 'abbezahlt')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [5 status] %', v_res; END IF;
  RAISE NOTICE 'PASS [5 Kredit: Depot-Rate / Status -> ok:false]';

  -- [6] Dauerauftrag: auf Depot / unbekannter Rhythmus
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__wg rp__','account_id', v_depot,'direction','expense',
    'amount',10,'schedule_unit','month','first_payment_date','2026-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 depot] %', v_res; END IF;
  SELECT finance.fn_create_recurring_payment(jsonb_build_object('name','__wg rp__','account_id', v_cash,'direction','expense',
    'amount',10,'schedule_unit','monatlich','first_payment_date','2026-01-01')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [6 rhythmus] %', v_res; END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE name = '__wg rp__') THEN RAISE EXCEPTION 'FAIL [6]: abgelehnt, aber angelegt'; END IF;
  RAISE NOTICE 'PASS [6 Dauerauftrag: Depot / Rhythmus -> ok:false]';

  -- [7] Sparziel: unbekannter Status
  SELECT (finance.fn_create_savings_goal(jsonb_build_object('name','__wg goal__','target_amount',1000,
    'monthly_savings_rate',100,'first_payment_date',(CURRENT_DATE + 1)::text,'account_id', v_cash,
    'reserve_account_id', (finance.fn_create_account('{"name":"__wg pot__","account_type":"cash"}'::jsonb)->>'account_id')::int
  ))->>'goal_id')::int INTO v_goal;
  IF v_goal IS NULL THEN RAISE EXCEPTION 'FAIL [7 setup]: Sparziel nicht angelegt'; END IF;
  SELECT finance.fn_set_savings_goal(jsonb_build_object('goal_id', v_goal, 'status', 'pausiert')) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [7 status] %', v_res; END IF;
  RAISE NOTICE 'PASS [7 Sparziel: unbekannter Status -> ok:false]';

  -- [8] Order-Gebuehr negativ: Kauf + Verkauf -> ok:false; CHECK-Backstop (V018)
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot,'settlement_id', v_cash,'isin','IE00B4L5Y983',
    'symbol','IWDA','name','World','shares',1,'price_per_share',100,'order_fee',-5,'transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR EXISTS (SELECT 1 FROM finance.depot_holdings WHERE account_id = v_depot) THEN
    RAISE EXCEPTION 'FAIL [8 buy] %', v_res;
  END IF;
  SELECT finance.fn_book_stock_buy(jsonb_build_object('depot_id', v_depot,'settlement_id', v_cash,'isin','IE00B4L5Y983',
    'symbol','IWDA','name','World','shares',1,'price_per_share',100,'order_fee',1,'transaction_date',CURRENT_DATE::text)) INTO v_res;
  SELECT finance.fn_book_stock_sell(jsonb_build_object('settlement_id', v_cash,'holding_id',(v_res->>'holding_id')::int,
    'shares',1,'price_per_share',100,'order_fee',-1,'transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [8 sell] %', v_res; END IF;
  v_ok := false;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, order_fee)
    VALUES (v_cash, -10, CURRENT_DATE, 'other', -1);
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [8 CHECK]: order_fee < 0 haette finance_transactions_order_fee_chk verletzen muessen'; END IF;
  RAISE NOTICE 'PASS [8 Order-Gebuehr negativ: Kauf/Verkauf ok:false, CHECK-Backstop]';

  -- [9] CHECK-Backstop Gutschrift-Tag (V018)
  v_ok := false;
  BEGIN
    INSERT INTO finance.account_interest_rates (account_id, annual_rate, schedule_interval, schedule_unit, posting_day_of_month, valid_from)
    VALUES (v_cash, 2, 1, 'month', -1, '2026-01-01');
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL [9 CHECK]: posting_day_of_month -1 haette finance_air_posting_dom_chk verletzen muessen'; END IF;
  RAISE NOTICE 'PASS [9 CHECK-Backstop Gutschrift-Tag 1-28]';

  -- [10] Rundungs-Paket 2026-10-23: Zinssatz/Tilgung mit > 4 Nachkommastellen oder >= 100 -> ok:false (numeric(6,4)
  -- kuerzte still bzw. warf Overflow); 3.5 und 3.50000 bleiben gueltig.
  SELECT finance.fn_create_account('{"name":"__wg r1__","account_type":"cash","interest_rate":3.12345}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 konto]: %', v_res; END IF;
  SELECT finance.fn_create_account('{"name":"__wg r2__","account_type":"cash","interest_rate":"3.50000","interest_credit_unit":"day"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [10 konto 3.50000 gueltig]: %', v_res; END IF;
  SELECT finance.fn_set_account_interest(jsonb_build_object('account_id', v_cash, 'annual_rate', 150)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 satz 150]: %', v_res; END IF;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__wg loan r__','original_amount',1000,'disbursement_date','2026-01-01',
    'interest_rate',3.12345,'principal_rate',2)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 kredit]: %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'principal_rate', 2.000001)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 kredit set]: %', v_res; END IF;
  -- Zins + Tilgung >= 100: GENERATED annuity_rate (numeric(6,4)) wuerde mit Overflow-RAISE abbrechen
  SELECT finance.fn_create_loan(jsonb_build_object('name','__wg loan sum__','original_amount',1000,'disbursement_date','2026-01-01',
    'interest_rate',60,'principal_rate',45)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 kredit summe]: %', v_res; END IF;
  SELECT finance.fn_set_loan(jsonb_build_object('loan_id', v_loan, 'interest_rate', 99)) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL [10 kredit set summe]: %', v_res; END IF;
  RAISE NOTICE 'PASS [10 Zinssatz-Praezision: > 4 Stellen / >= 100 -> ok:false, 3.50000 ok]';
END $$;

ROLLBACK;
