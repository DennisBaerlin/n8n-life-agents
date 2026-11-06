-- tests/db/finance/test_transactions_dedup_index.sql
-- WP-1 Doppelbuchungs-Riegel: die 2 partiellen UNIQUE-Indizes auf finance.transactions sind das Gesetz
-- (struktureller Backstop gegen das TOCTOU-Race der EXISTS-vor-INSERT-Idempotenz). Beweist:
--   (a) beide Indizes existieren, sind UNIQUE + partiell (korrektes Praedikat/Spalten),
--   (b) direktes Doppel-DML auf den Key -> unique_violation (recurring + interest),
--   (c) das Praedikat schliesst legitime Faelle korrekt aus/ein: generische Zins-Tx (period_end NULL) ->
--       kein Konflikt; die ZWEI Transfer-Beine (gleiche rp/date, versch. account_id) -> kein Konflikt (3-spaltig),
--   (d) fn_book_stock_buy (Sparplan-Pfad) idempotent: Doppel-Ausfuehrung -> 2. {ok:false}, kein Orphan/Doppel.
BEGIN;
DO $$
DECLARE
  v_acct INT; v_depot INT; v_rp INT; v_tx1 INT; v_res JSONB; v_res2 JSONB;
  v_def TEXT; v_uniq BOOLEAN; v_pred TEXT; v_cnt INT;
BEGIN
  -- ===== (a) Index-Existenz + UNIQUE + partiell =====
  SELECT ix.indisunique, pg_get_expr(ix.indpred, ix.indrelid)
    INTO v_uniq, v_pred
    FROM pg_class c JOIN pg_index ix ON ix.indexrelid = c.oid
   WHERE c.relname = 'finance_transactions_recurring_due_uq';
  IF v_uniq IS NULL THEN RAISE EXCEPTION 'FAIL: recurring_due_uq Index fehlt'; END IF;
  IF NOT v_uniq THEN RAISE EXCEPTION 'FAIL: recurring_due_uq ist nicht UNIQUE'; END IF;
  IF v_pred IS NULL OR v_pred NOT LIKE '%recurring_payment_id IS NOT NULL%' THEN
    RAISE EXCEPTION 'FAIL: recurring_due_uq ohne Partial-Praedikat (recurring_payment_id IS NOT NULL), got %', COALESCE(v_pred,'<null>'); END IF;
  -- Monats-Check WP-A: der Vorgaenger auf transaction_date ist weg (finance:V015)
  IF EXISTS (SELECT 1 FROM pg_class WHERE relname = 'finance_transactions_recurring_occurrence_uq') THEN
    RAISE EXCEPTION 'FAIL: alter Index recurring_occurrence_uq (transaction_date) existiert noch'; END IF;

  SELECT ix.indisunique, pg_get_expr(ix.indpred, ix.indrelid)
    INTO v_uniq, v_pred
    FROM pg_class c JOIN pg_index ix ON ix.indexrelid = c.oid
   WHERE c.relname = 'finance_transactions_interest_occurrence_uq';
  IF v_uniq IS NULL THEN RAISE EXCEPTION 'FAIL: interest_occurrence_uq Index fehlt'; END IF;
  IF NOT v_uniq THEN RAISE EXCEPTION 'FAIL: interest_occurrence_uq ist nicht UNIQUE'; END IF;
  IF v_pred IS NULL OR v_pred NOT LIKE '%interest_period_end IS NOT NULL%' THEN
    RAISE EXCEPTION 'FAIL: interest_occurrence_uq ohne period_end IS NOT NULL im Praedikat, got %', COALESCE(v_pred,'<null>'); END IF;
  RAISE NOTICE 'PASS [(a) beide Indizes: UNIQUE + partiell]';

  -- Setup: ein Konto + eine recurring_payment.
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__dedup_cash__', 'cash', 'EUR', 'active') RETURNING id INTO v_acct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__dedup_rp__', v_acct, -100, 'month', DATE '2026-01-01', DATE '2026-01-01') RETURNING id INTO v_rp;

  -- ===== (b) recurring: direktes Doppel-DML auf (rp, due, account) -> unique_violation (ohne explizite
  --       Faelligkeit setzt trg_finance_default_recurring_due_date due = transaction_date) =====
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id)
    VALUES (v_acct, -100, DATE '2026-01-15', 'other', v_rp);
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id)
      VALUES (v_acct, -100, DATE '2026-01-15', 'other', v_rp);
    RAISE EXCEPTION 'FAIL [(b) recurring]: Doppel-INSERT (rp,date,account) nicht abgewiesen';
  EXCEPTION WHEN unique_violation THEN NULL; END;

  -- ===== (b) interest: direktes Doppel-DML auf (account, period_end) mit period_end NOT NULL =====
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
    VALUES (v_acct, 5, DATE '2026-02-01', 'interest', DATE '2026-01-31');
  BEGIN
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
      VALUES (v_acct, 5, DATE '2026-02-01', 'interest', DATE '2026-01-31');
    RAISE EXCEPTION 'FAIL [(b) interest]: Doppel-INSERT (account,period_end) nicht abgewiesen';
  EXCEPTION WHEN unique_violation THEN NULL; END;
  RAISE NOTICE 'PASS [(b) direktes Doppel-DML abgewiesen (recurring + interest)]';

  -- ===== (c1) generische Zins-Tx (period_end NULL) -> kein Konflikt (Praedikat schliesst sie aus) =====
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
    VALUES (v_acct, 3, DATE '2026-03-01', 'interest', NULL);
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, interest_period_end)
    VALUES (v_acct, 3, DATE '2026-03-01', 'interest', NULL);   -- MUSS durchgehen (period_end NULL != Arbiter)
  RAISE NOTICE 'PASS [(c1) generische Zins-Tx period_end NULL: kein Konflikt, bookbar]';

  -- ===== (c2) zwei Transfer-Beine (gleiche rp/date, versch. account_id) -> kein Konflikt (3-spaltiger Key) =====
  INSERT INTO finance.accounts (name, account_type, currency, status)
    VALUES ('__dedup_cash2__', 'cash', 'EUR', 'active') RETURNING id INTO v_depot;   -- 2. Konto (Ziel-Bein)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, group_id)
    VALUES (v_acct, -50, DATE '2026-04-15', 'transfer', v_rp, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, group_id)
    VALUES (v_depot, 50, DATE '2026-04-15', 'transfer', v_rp, gen_random_uuid());   -- MUSS durchgehen (anderes account_id)
  RAISE NOTICE 'PASS [(c2) zwei Transfer-Beine (rp,date gleich, account versch.): kein Konflikt]';

  -- ===== (d) fn_book_stock_buy Sparplan-Pfad: Doppel-Ausfuehrung -> 2. {ok:false}, kein Orphan/Doppel =====
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__dedup_depot__', 'stocks_depot', 'EUR', 'active', v_acct) RETURNING id INTO v_depot;
  v_res := finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot, 'settlement_id', v_acct, 'isin', 'DE000DEDUP1', 'symbol', 'DED',
    'name', 'Dedup AG', 'shares', 1, 'price_per_share', 100, 'order_fee', 0,
    'transaction_date', '2026-05-15', 'recurring_payment_id', v_rp));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [(d)]: 1. Sparplan-Kauf nicht ok:true, got %', v_res; END IF;
  v_res2 := finance.fn_book_stock_buy(jsonb_build_object(
    'depot_id', v_depot, 'settlement_id', v_acct, 'isin', 'DE000DEDUP1', 'symbol', 'DED',
    'name', 'Dedup AG', 'shares', 1, 'price_per_share', 100, 'order_fee', 0,
    'transaction_date', '2026-05-15', 'recurring_payment_id', v_rp));
  IF (v_res2->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [(d)]: 2. Sparplan-Kauf nicht ok:false (Idempotenz), got %', v_res2; END IF;
  SELECT count(*) INTO v_cnt FROM finance.transactions
    WHERE recurring_payment_id = v_rp AND transaction_date = DATE '2026-05-15' AND category = 'buy';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [(d)]: erwartet 1 Kauf-Tx, got %', v_cnt; END IF;
  SELECT count(*) INTO v_cnt FROM finance.depot_holdings WHERE account_id = v_depot AND isin = 'DE000DEDUP1';
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL [(d)]: erwartet 1 Holding (kein Orphan/Doppel), got %', v_cnt; END IF;
  RAISE NOTICE 'PASS [(d) fn_book_stock_buy Sparplan-Pfad idempotent: 1 Kauf-Tx, 1 Holding]';
END $$;
ROLLBACK;
