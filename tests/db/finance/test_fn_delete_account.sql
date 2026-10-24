-- tests/db/finance/test_fn_delete_account.sql
-- Testet fn_delete_account: Hard-DELETE (leeres Konto), Guards (Transaktion / Verrechnungskonto
-- eines aktiven Depots), not-found. Loescht balance-Zeile explizit (kein CASCADE).
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_empty  INT;
  v_tx     INT;
  v_cash   INT;
  v_depot  INT;
  v_cnt    INT;
BEGIN
  -- Konto A: leer -> loeschbar
  SELECT (finance.fn_create_account('{"name":"__test_da_empty__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_empty;

  -- Konto B: mit Transaktion -> Guard
  SELECT (finance.fn_create_account('{"name":"__test_da_tx__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_tx;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
  VALUES (v_tx, -50, CURRENT_DATE, 'other');

  -- Konto C: Verrechnungskonto eines aktiven Depots -> Guard
  SELECT (finance.fn_create_account('{"name":"__test_da_cash__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_cash;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_da_depot__','account_type','stocks_depot','account_holder','T','currency','EUR','settlement_id',v_cash))->>'account_id')::int INTO v_depot;

  -- TEST 1: Hard-DELETE des leeren Kontos (+ balance-Zeile weg)
  SELECT finance.fn_delete_account('{"account_name":"__test_da_empty__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR v_res->>'action' IS DISTINCT FROM 'deleted' THEN
    RAISE EXCEPTION 'FAIL delete_account [hard-delete]: %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_empty;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_account [Konto noch da]'; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.account_balances WHERE account_id = v_empty;
  IF v_cnt <> 0 THEN RAISE EXCEPTION 'FAIL delete_account [balance-Zeile noch da]'; END IF;
  RAISE NOTICE 'PASS delete_account [Hard-DELETE + balance-Zeile weg]';

  -- TEST 2: Guard Transaktion -> {ok:false}, nichts geloescht
  SELECT finance.fn_delete_account('{"account_name":"__test_da_tx__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete_account [tx-guard]: erwartet ok=false, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_tx;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_account [Konto B faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_account [tx-guard: ok=false, Konto bleibt]';

  -- TEST 3: Guard Verrechnungskonto eines aktiven Depots -> {ok:false}
  SELECT finance.fn_delete_account('{"account_name":"__test_da_cash__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL delete_account [settlement-guard]: erwartet ok=false, got %', v_res; END IF;
  SELECT COUNT(*) INTO v_cnt FROM finance.accounts WHERE id = v_cash;
  IF v_cnt <> 1 THEN RAISE EXCEPTION 'FAIL delete_account [Verrechnungskonto faelschlich geloescht]'; END IF;
  RAISE NOTICE 'PASS delete_account [settlement-guard: ok=false]';

  -- TEST 3b (Audit Paket 2, Punkt 14): Konto ist ZIEL eines Dauer-Uebertrags -> {ok:false} mit Zaehler statt FK-RAISE.
  DECLARE v_tgt INT; v_src INT; v_rp INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_da_tgt__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_tgt;
    SELECT (finance.fn_create_account('{"name":"__test_da_src__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_src;
    v_rp := finance.fn_add_recurring_payment(v_src, -100, '__test_da_rp__', 1::smallint, 'month', NULL,
      CURRENT_DATE, CURRENT_DATE, NULL, 'active', NULL);
    UPDATE finance.recurring_payments SET target_account_id = v_tgt WHERE id = v_rp;
    SELECT finance.fn_delete_account('{"account_name":"__test_da_tgt__"}'::jsonb) INTO v_res;
    IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR (v_res->>'recurring_target_count')::int IS DISTINCT FROM 1 THEN
      RAISE EXCEPTION 'FAIL delete_account [target-guard]: erwartet ok=false + recurring_target_count 1, got %', v_res; END IF;
    RAISE NOTICE 'PASS delete_account [Ziel eines Dauer-Uebertrags -> ok:false, recurring_target_count=1]';
  END;

  -- TEST 4: not-found -> {ok:false, reason, candidates} als Daten (Vertragsaenderung DB-ist-das-Gesetz: Probelauf vor der Karte)
  SELECT finance.fn_delete_account('{"account_name":"__test_da_missing__"}'::jsonb) INTO v_res;
  IF (v_res->>'ok')::boolean IS DISTINCT FROM false OR v_res->>'reason' NOT LIKE '%not found%' OR NOT (v_res ? 'candidates') THEN
    RAISE EXCEPTION 'FAIL delete_account [not-found -> ok:false]: %', v_res; END IF;
  RAISE NOTICE 'PASS delete_account [not-found -> ok:false]';
END $$;

ROLLBACK;
