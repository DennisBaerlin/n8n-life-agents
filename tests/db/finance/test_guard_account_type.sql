-- tests/db/finance/test_guard_account_type.sql
-- Audit Paket 2, Punkt 7: Kontotyp-Guard. Buchung/Uebertrag/Abgleich auf ein DEPOT-Konto liess Geld aus dem
--   Vermoegen verschwinden (Depot-Konten zaehlen nicht im Networth, der Wert steckt in den Holdings); auf ein
--   KREDIT-Konto entstand eine Restschuld ohne loan_id (Abgleich "Restschuld 298.000" buchte +298.000).
--   fn-Ebene: {ok:false} mit Hinweis (kein RAISE/Owner-Alarm). Backstop: Trigger trg_finance_reject_account_type_txn
--   (Depot nie, Kreditkonto nur mit loan_id).
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_cash  INT;
  v_depot INT;
  v_loan  INT;
  v_lacc  INT;
  v_rp    INT;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_gat_cash__','account_type','cash',
    'currency','EUR'))->>'account_id')::int INTO v_cash;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_gat_depot__','account_type','stocks_depot',
    'currency','EUR','settlement_id', v_cash))->>'account_id')::int INTO v_depot;
  SELECT finance.fn_create_loan(jsonb_build_object('name','__test_gat_kredit__','lender','B','borrower','T',
    'original_amount',300000,'current_balance',298000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',3,
    'monthly_annuity',1500,'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_cash)) INTO v_res;
  v_loan := (v_res->>'loan_id')::int;
  v_lacc := (v_res->>'loan_account_id')::int;

  -- 1. book_transaction: Depot / Kreditkonto -> ok:false, nichts gebucht
  v_res := finance.fn_book_transaction(jsonb_build_object('account_id',v_depot,'amount',500,'direction','outflow',
    'transaction_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [book_transaction Depot]: %', v_res; END IF;
  v_res := finance.fn_book_transaction(jsonb_build_object('account_id',v_lacc,'amount',500,'direction','inflow',
    'transaction_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [book_transaction Kredit]: %', v_res; END IF;
  RAISE NOTICE 'PASS guard [book_transaction auf Depot/Kreditkonto -> ok:false]';

  -- 2. book_transfer: Ziel Depot / Quelle Kreditkonto -> ok:false
  v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_cash,'to_account_id',v_depot,'from_amount',100,
    'transaction_date',CURRENT_DATE::text,'from_account_name','c','to_account_name','d'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [book_transfer Depot]: %', v_res; END IF;
  v_res := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_lacc,'to_account_id',v_cash,'from_amount',100,
    'transaction_date',CURRENT_DATE::text,'from_account_name','k','to_account_name','c'));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [book_transfer Kredit]: %', v_res; END IF;
  RAISE NOTICE 'PASS guard [book_transfer mit Depot/Kreditkonto -> ok:false]';

  -- 3. reconcile: Kreditkonto ("Restschuld 298000" positiv) / Depot -> ok:false, auch im Batch (Vorschau + Buchung)
  v_res := finance.fn_reconcile_account(jsonb_build_object('account_id',v_lacc,'confirmed_balance',298000,
    'reconciliation_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [reconcile Kredit]: %', v_res; END IF;
  IF finance.fn_get_balance(v_lacc) IS DISTINCT FROM -298000.00 THEN
    RAISE EXCEPTION 'FAIL guard [reconcile Kredit]: Saldo veraendert auf %', finance.fn_get_balance(v_lacc); END IF;
  v_res := finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
    jsonb_build_object('account_name','__test_gat_depot__','confirmed_balance','100'))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [reconcile_accounts Depot]: %', v_res; END IF;
  v_res := finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
    jsonb_build_object('account_name','__test_gat_depot__','confirmed_balance','100'))));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [reconcile preview Depot]: %', v_res; END IF;
  RAISE NOTICE 'PASS guard [Abgleich Kredit/Depot -> ok:false, auch Batch + Vorschau]';

  -- 4. Dauer-Uebertrag ins Depot -> ok:false (vorher kein Guard)
  v_rp := finance.fn_add_recurring_payment(v_cash, -50, '__test_gat_rp__', 1::smallint, 'month', NULL,
    CURRENT_DATE, CURRENT_DATE, NULL, 'active', NULL);
  UPDATE finance.recurring_payments SET target_account_id = v_depot WHERE id = v_rp;
  v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [Dauer-Uebertrag Depot]: %', v_res; END IF;
  RAISE NOTICE 'PASS guard [Dauer-Uebertrag ins Depot -> ok:false]';

  -- 4b. Review: Kreditrate / Abloesung aus einem Depot, Immobilien-Erloes aufs Depot -> ok:false statt Alarm
  v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_lacc,
    'debit_account_id',v_depot,'payment_amount',1500,'payment_date',CURRENT_DATE::text));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [Kreditrate aus Depot]: %', v_res; END IF;
  v_res := finance.fn_settle_loan(jsonb_build_object('loan_name','__test_gat_kredit__','debit_account_id',v_depot));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [Abloesung aus Depot]: %', v_res; END IF;
  PERFORM finance.fn_create_real_estate(jsonb_build_object('name','__test_gat_haus__','current_value',100000));
  v_res := finance.fn_sell_real_estate(jsonb_build_object('real_estate_name','__test_gat_haus__','sale_price',120000,
    'proceeds_account_id',v_depot));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL guard [Erloes aufs Depot]: %', v_res; END IF;
  RAISE NOTICE 'PASS guard [Kreditrate/Abloesung aus Depot, Erloes aufs Depot -> ok:false]';

  -- 5. Backstop-Trigger: direkter INSERT aufs Depot -> Fehler; aufs Kreditkonto ohne loan_id -> Fehler; mit loan_id ok
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date) VALUES (v_depot, -1, CURRENT_DATE);
    RAISE EXCEPTION 'FAIL guard [Trigger Depot]: INSERT akzeptiert';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date) VALUES (v_lacc, 1, CURRENT_DATE);
    RAISE EXCEPTION 'FAIL guard [Trigger Kredit ohne loan_id]: INSERT akzeptiert';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM LIKE 'FAIL%' THEN RAISE; END IF;
  END;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
  VALUES (v_lacc, 1, CURRENT_DATE, 'principal', v_loan);
  RAISE NOTICE 'PASS guard [Trigger: Depot nie, Kreditkonto nur mit loan_id]';
END $$;

ROLLBACK;
