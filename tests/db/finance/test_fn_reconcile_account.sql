-- tests/db/finance/test_fn_reconcile_account.sql
-- Testet fn_reconcile_account: ohne Differenz (kein TX), mit Differenz (+/- Korrekturbuchung)
BEGIN;

DO $$
DECLARE
  v_result      JSONB;
  v_acct_id     INT;
  v_got_bal     NUMERIC;
  v_got_ts      DATE;
  v_got_last    NUMERIC;
  v_tx_id       INT;
BEGIN

  -- Setup: Konto
  SELECT finance.fn_create_account(
    '{"name":"__test_reconcile_acct__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_acct_id := (v_result->>'account_id')::int;

  -- Setup: Transaktion -> Balance = 1000
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_acct_id, 1000, CURRENT_DATE, 'other', 'Test-Einlage');

  -- TEST 1: Abgleich ohne Differenz (confirmed = db_balance = 1000)
  SELECT finance.fn_reconcile_account(jsonb_build_object(
    'account_id',         v_acct_id,
    'confirmed_balance',  1000,
    'reconciliation_date', CURRENT_DATE::text,
    'notes',              ''
  )) INTO v_result;

  IF (v_result->>'difference')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [kein Diff]: erwartet 0, got %', v_result->>'difference';
  END IF;
  IF (v_result->>'reconciliation_tx_id') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [kein TX]: kein TX erwartet, aber einer angelegt';
  END IF;
  IF (v_result->>'currency') IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [currency]: erwartet EUR, got %', v_result->>'currency';
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [kein Diff, kein TX, currency=EUR]';

  -- Assert: last_reconciled_balance + last_reconciled_at gesetzt
  SELECT last_reconciled_balance, last_reconciled_at
  INTO v_got_last, v_got_ts
  FROM finance.accounts WHERE id = v_acct_id;
  IF v_got_last IS DISTINCT FROM 1000 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [last_reconciled_balance]: erwartet 1000, got %', v_got_last;
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [last_reconciled_balance=%]', v_got_last;

  -- TEST 2: Abgleich mit positivem Drift (+20)
  SELECT finance.fn_reconcile_account(jsonb_build_object(
    'account_id',         v_acct_id,
    'confirmed_balance',  1020,
    'reconciliation_date', CURRENT_DATE::text,
    'notes',              'Zinsgutschrift vergessen'
  )) INTO v_result;

  IF (v_result->>'difference')::numeric IS DISTINCT FROM 20 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [+drift]: erwartet 20, got %', v_result->>'difference';
  END IF;
  v_tx_id := (v_result->>'reconciliation_tx_id')::int;
  IF v_tx_id IS NULL THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [+drift TX]: TX-ID erwartet, aber NULL';
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [+drift: TX angelegt, id=%]', v_tx_id;

  -- Assert: Balance nach Korrekturbuchung = 1020
  SELECT finance.fn_get_balance(v_acct_id) INTO v_got_bal;
  IF v_got_bal IS DISTINCT FROM 1020 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [+drift Balance]: erwartet 1020, got %', v_got_bal;
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [+drift Balance=%]', v_got_bal;

  -- Assert: Korrektur-TX hat category='reconciliation'
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_tx_id AND category = 'reconciliation' AND amount = 20
  ) THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account: Korrektur-TX category/amount falsch';
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [Korrektur-TX category korrekt]';

  -- TEST 3: Negativer Drift (-50): Balance ist 1020, confirmed = 970
  SELECT finance.fn_reconcile_account(jsonb_build_object(
    'account_id',         v_acct_id,
    'confirmed_balance',  970,
    'reconciliation_date', CURRENT_DATE::text,
    'notes',              'Buchungsfehler'
  )) INTO v_result;

  IF (v_result->>'difference')::numeric IS DISTINCT FROM -50 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [-drift]: erwartet -50, got %', v_result->>'difference';
  END IF;
  SELECT finance.fn_get_balance(v_acct_id) INTO v_got_bal;
  IF v_got_bal IS DISTINCT FROM 970 THEN
    RAISE EXCEPTION 'FAIL fn_reconcile_account [-drift Balance]: erwartet 970, got %', v_got_bal;
  END IF;
  RAISE NOTICE 'PASS fn_reconcile_account [-drift: Balance=%]', v_got_bal;

  -- TEST 4-9 (Audit Paket 2, Punkt 6): Abgleich zum STICHTAG. Beispiel: 1000 bis D-10, +300 am D-3; der Nutzer
  -- sagt "am D-5 waren es 1000" -> Differenz 0 (vorher Vergleich mit dem HEUTIGEN Saldo 1300 -> Korrektur -300).
  DECLARE v_a INT; v_b INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_rca_asof__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_a;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_a, 1000, CURRENT_DATE - 10, 'other'), (v_a, 300, CURRENT_DATE - 3, 'other');
    IF finance.fn_get_balance_as_of(v_a, CURRENT_DATE - 5) IS DISTINCT FROM 1000.00
       OR finance.fn_get_balance_as_of(v_a, CURRENT_DATE - 3) IS DISTINCT FROM 1300.00 THEN
      RAISE EXCEPTION 'FAIL get_balance_as_of: D-5=% D-3=%', finance.fn_get_balance_as_of(v_a, CURRENT_DATE - 5),
        finance.fn_get_balance_as_of(v_a, CURRENT_DATE - 3); END IF;

    -- Vorschau (Batch) = Buchung: beide vergleichen mit dem Saldo zum Stichtag
    SELECT finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(jsonb_build_object(
      'account_name','__test_rca_asof__','confirmed_balance','1000','reconciliation_date',(CURRENT_DATE - 5)::text)))) INTO v_result;
    IF (v_result->'rows'->0->>'diff')::numeric IS DISTINCT FROM 0 OR (v_result->'rows'->0->>'db_balance')::numeric IS DISTINCT FROM 1000 THEN
      RAISE EXCEPTION 'FAIL reconcile [Vorschau Stichtag]: erwartet db_balance 1000 / diff 0, got %', v_result; END IF;
    SELECT finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1000,
      'reconciliation_date', (CURRENT_DATE - 5)::text)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM true OR (v_result->>'difference')::numeric IS DISTINCT FROM 0
       OR v_result->>'reconciliation_tx_id' IS NOT NULL OR (v_result->>'balance_after')::numeric IS DISTINCT FROM 1300 THEN
      RAISE EXCEPTION 'FAIL reconcile [Stichtag]: erwartet ok/diff 0/kein TX/balance_after 1300, got %', v_result; END IF;
    RAISE NOTICE 'PASS reconcile [Stichtag D-5: Saldo damals 1000 -> keine Korrektur; Vorschau = Buchung]';

    -- Stichtag VOR dem letzten Abgleich -> ok:false (verschoebe einen schon bestaetigten Saldo); Zukunft -> ok:false
    SELECT finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 900,
      'reconciliation_date', (CURRENT_DATE - 8)::text)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL reconcile [vor letztem Abgleich]: erwartet ok=false, got %', v_result; END IF;
    SELECT finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 900,
      'reconciliation_date', (CURRENT_DATE + 1)::text)) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL reconcile [Zukunft]: erwartet ok=false, got %', v_result; END IF;
    IF finance.fn_get_balance(v_a) IS DISTINCT FROM 1300.00 THEN
      RAISE EXCEPTION 'FAIL reconcile [Guards ohne Write]: Saldo %', finance.fn_get_balance(v_a); END IF;
    RAISE NOTICE 'PASS reconcile [Stichtag vor letztem Abgleich / in der Zukunft -> ok:false, kein Write]';

    -- Rundung: bestaetigter Saldo 1300.005 -> 1300.01 (Differenz 0.01, gespeichert 1300.01); fehlendes Datum -> heute
    SELECT finance.fn_reconcile_account(jsonb_build_object('account_id', v_a, 'confirmed_balance', 1300.005)) INTO v_result;
    IF (v_result->>'difference')::numeric IS DISTINCT FROM 0.01
       OR (SELECT last_reconciled_balance FROM finance.accounts WHERE id = v_a) IS DISTINCT FROM 1300.01
       OR (SELECT last_reconciled_at FROM finance.accounts WHERE id = v_a) IS DISTINCT FROM CURRENT_DATE THEN
      RAISE EXCEPTION 'FAIL reconcile [Rundung/Datum]: %', v_result; END IF;
    RAISE NOTICE 'PASS reconcile [1300.005 -> 1300.01, ohne Datum = heute]';

    -- <=-Grenze: Buchung AM Stichtag zaehlt mit
    SELECT (finance.fn_create_account('{"name":"__test_rca_edge__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_b;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_b, 1000, CURRENT_DATE - 10, 'other'), (v_b, 200, CURRENT_DATE - 5, 'other');
    SELECT finance.fn_reconcile_account(jsonb_build_object('account_id', v_b, 'confirmed_balance', 1200,
      'reconciliation_date', (CURRENT_DATE - 5)::text)) INTO v_result;
    IF (v_result->>'difference')::numeric IS DISTINCT FROM 0 THEN
      RAISE EXCEPTION 'FAIL reconcile [<=-Grenze]: erwartet diff 0, got %', v_result; END IF;
    RAISE NOTICE 'PASS reconcile [Buchung am Stichtag zaehlt mit]';

    -- Doppeltes Konto im Batch -> ok:false in Vorschau UND Buchung (sonst wiche die Vorschau von der Buchung ab)
    SELECT finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_rca_edge__','confirmed_balance','1200'),
      jsonb_build_object('account_name','__test_rca_edge__','confirmed_balance','1250')))) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL reconcile [Batch doppelt Vorschau]: %', v_result; END IF;
    SELECT finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_rca_edge__','confirmed_balance','1200'),
      jsonb_build_object('account_name','__test_rca_edge__','confirmed_balance','1250')))) INTO v_result;
    IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR finance.fn_get_balance(v_b) IS DISTINCT FROM 1200.00 THEN
      RAISE EXCEPTION 'FAIL reconcile [Batch doppelt Buchung]: % Saldo %', v_result, finance.fn_get_balance(v_b); END IF;
    RAISE NOTICE 'PASS reconcile [doppeltes Konto im Batch -> ok:false in Vorschau und Buchung]';
  END;

END $$;

ROLLBACK;
