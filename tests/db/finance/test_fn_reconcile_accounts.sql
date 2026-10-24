-- tests/db/finance/test_fn_reconcile_accounts.sql
-- Testet fn_reconcile_accounts_preview (read-only) + fn_reconcile_accounts (atomarer Batch):
-- Multi-Konto, Diff-Buchung nur bei !=0, native Waehrung, Atomaritaet bei Fehler, leere/0-Treffer.
BEGIN;

DO $$
DECLARE
  v_result   JSONB;
  v_a1       INT;
  v_a2       INT;
  v_rows     JSONB;
  v_bal      NUMERIC;
  v_last     NUMERIC;
BEGIN
  -- Setup: zwei Cash-Konten
  SELECT finance.fn_create_account('{"name":"__test_recon_batch_a__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_result;
  v_a1 := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_recon_batch_b__","account_type":"cash","account_holder":"T","currency":"KRW"}'::jsonb) INTO v_result;
  v_a2 := (v_result->>'account_id')::int;

  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES (v_a1, 1000, CURRENT_DATE, 'other', 'Einlage A'),
         (v_a2, 500000, CURRENT_DATE, 'other', 'Einlage B');

  -- TEST 1: Preview liefert ok + rows mit korrektem Saldo/Waehrung/Diff
  SELECT finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_recon_batch_a__','confirmed_balance',1020),
      jsonb_build_object('account_name','__test_recon_batch_b__','confirmed_balance',500000)
  ))) INTO v_result;

  IF (v_result->>'ok')::boolean IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'FAIL preview [ok]: erwartet true, got %', v_result->>'ok';
  END IF;
  IF (v_result->>'n')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL preview [n]: erwartet 2, got %', v_result->>'n';
  END IF;
  v_rows := v_result->'rows';
  -- Konto A: db_balance 1000, confirmed 1020, diff 20, currency EUR
  IF (v_rows->0->>'db_balance')::numeric IS DISTINCT FROM 1000
     OR (v_rows->0->>'diff')::numeric IS DISTINCT FROM 20
     OR (v_rows->0->>'currency') IS DISTINCT FROM 'EUR' THEN
    RAISE EXCEPTION 'FAIL preview [row A]: %', v_rows->0;
  END IF;
  -- Konto B: KRW, diff 0
  IF (v_rows->1->>'currency') IS DISTINCT FROM 'KRW'
     OR (v_rows->1->>'diff')::numeric IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL preview [row B]: %', v_rows->1;
  END IF;
  RAISE NOTICE 'PASS preview [ok, n=2, native currency, diffs]';

  -- TEST 2: Batch-Write -> beide reconciled; nur A bekommt Korrekturbuchung (+20)
  SELECT finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_recon_batch_a__','confirmed_balance',1020),
      jsonb_build_object('account_name','__test_recon_batch_b__','confirmed_balance',500000)
  ))) INTO v_result;

  IF (v_result->>'ok')::boolean IS DISTINCT FROM TRUE
     OR (v_result->>'count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL batch [ok/count]: %', v_result;
  END IF;
  -- A: Saldo nach Korrektur = 1020, last_reconciled gesetzt, currency im Ergebnis
  SELECT finance.fn_get_balance(v_a1) INTO v_bal;
  IF v_bal IS DISTINCT FROM 1020 THEN
    RAISE EXCEPTION 'FAIL batch [A balance]: erwartet 1020, got %', v_bal;
  END IF;
  IF (v_result->'results'->0->>'currency') IS DISTINCT FROM 'EUR'
     OR (v_result->'results'->0->>'reconciliation_tx_id') IS NULL THEN
    RAISE EXCEPTION 'FAIL batch [A result currency/tx]: %', v_result->'results'->0;
  END IF;
  -- B: kein Diff -> kein TX, aber last_reconciled gesetzt
  IF (v_result->'results'->1->>'reconciliation_tx_id') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL batch [B no-diff TX]: unerwarteter TX';
  END IF;
  SELECT last_reconciled_balance INTO v_last FROM finance.accounts WHERE id = v_a2;
  IF v_last IS DISTINCT FROM 500000 THEN
    RAISE EXCEPTION 'FAIL batch [B last_reconciled]: erwartet 500000, got %', v_last;
  END IF;
  RAISE NOTICE 'PASS batch [beide reconciled, nur A Korrekturbuchung]';

  -- TEST 3: Atomaritaet -> ein gueltiges + ein unbekanntes Konto -> ok:false, KEIN Write
  -- Reset: neues Konto C ohne Reconcile-Historie
  SELECT finance.fn_create_account('{"name":"__test_recon_batch_c__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb) INTO v_result;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, description)
  VALUES ((v_result->>'account_id')::int, 300, CURRENT_DATE, 'other', 'Einlage C');

  SELECT finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_recon_batch_c__','confirmed_balance',350),
      jsonb_build_object('account_name','__test_does_not_exist__','confirmed_balance',999)
  ))) INTO v_result;

  IF (v_result->>'ok')::boolean IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FAIL batch-atomic [ok]: erwartet false, got %', v_result;
  END IF;
  -- C darf NICHT reconciled/gebucht worden sein (RETURN brach die TX-Logik vor dem Write ab)
  SELECT last_reconciled_at INTO v_last FROM finance.accounts
    WHERE name = '__test_recon_batch_c__';
  IF v_last IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL batch-atomic: Konto C wurde trotz Fehler reconciled (Teilzustand!)';
  END IF;
  RAISE NOTICE 'PASS batch-atomic [unbekanntes Konto -> ok:false, kein Teilzustand]';

  -- TEST 4: Leere Liste -> ok:false
  SELECT finance.fn_reconcile_accounts('{"accounts":[]}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FAIL batch [leer]: erwartet false';
  END IF;
  RAISE NOTICE 'PASS batch [leere Liste -> ok:false]';

  -- TEST 5: Preview-Negativ-Pfade -- unbekanntes Konto -> ok:false + candidates; leere Liste -> ok:false
  SELECT finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_does_not_exist__','confirmed_balance',999)
  ))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM FALSE
     OR (v_result->'candidates') IS NULL THEN
    RAISE EXCEPTION 'FAIL preview [unbekannt]: erwartet ok:false + candidates, got %', v_result;
  END IF;
  SELECT finance.fn_reconcile_accounts_preview('{"accounts":[]}'::jsonb) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM FALSE THEN
    RAISE EXCEPTION 'FAIL preview [leer]: erwartet false';
  END IF;
  RAISE NOTICE 'PASS preview [unbekanntes Konto + leere Liste -> ok:false]';

  -- TEST 6: Preview ist READ-ONLY -- kein last_reconciled, keine Korrekturbuchung (Konto C aus TEST 3)
  SELECT finance.fn_reconcile_accounts_preview(jsonb_build_object('accounts', jsonb_build_array(
      jsonb_build_object('account_name','__test_recon_batch_c__','confirmed_balance',350)
  ))) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'FAIL preview-ro [ok]: %', v_result;
  END IF;
  SELECT last_reconciled_at INTO v_last FROM finance.accounts
    WHERE name = '__test_recon_batch_c__';
  IF v_last IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL preview-ro: Preview hat last_reconciled_at gesetzt (Write in Read-Pfad!)';
  END IF;
  IF EXISTS (SELECT 1 FROM finance.transactions t
             JOIN finance.accounts a ON a.id = t.account_id
             WHERE a.name = '__test_recon_batch_c__' AND t.category = 'reconciliation') THEN
    RAISE EXCEPTION 'FAIL preview-ro: Preview hat eine Korrekturbuchung erzeugt (Write in Read-Pfad!)';
  END IF;
  RAISE NOTICE 'PASS preview [read-only: kein last_reconciled, keine Buchung]';

END $$;

-- ============================================================
-- Phase B: Modell-Eingaben -> {ok:false} statt Absturz (Build-Sentinel bei kaputtem JSON, fehlender Key,
-- nicht-numerischer Saldo, kaputtes Datum) — beide fns, kein Write.
-- ============================================================
DO $$
DECLARE r jsonb;
BEGIN
  FOREACH r IN ARRAY ARRAY[
      finance.fn_reconcile_accounts('{"accounts": "__invalid_json__"}'),
      finance.fn_reconcile_accounts('{}'),
      finance.fn_reconcile_accounts_preview('{"accounts": "__invalid_json__"}'),
      finance.fn_reconcile_accounts_preview('{}')] LOOP
    IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%No accounts provided%' THEN
      RAISE EXCEPTION 'FAIL guards [kein Array / fehlender Key -> ok:false]: %', r; END IF;
  END LOOP;
  r := finance.fn_reconcile_accounts('{"accounts": [{"account_name": "x", "confirmed_balance": "1.234,56"}]}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%plain number%' THEN
    RAISE EXCEPTION 'FAIL guards [Saldo deutsch formatiert]: %', r; END IF;
  r := finance.fn_reconcile_accounts_preview('{"accounts": [{"account_name": "x", "confirmed_balance": "abc"}]}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%plain number%' THEN
    RAISE EXCEPTION 'FAIL guards [preview Saldo nicht numerisch]: %', r; END IF;
  r := finance.fn_reconcile_accounts('{"accounts": [{"account_name": "x", "confirmed_balance": 10, "reconciliation_date": "31.12.2026"}]}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%YYYY-MM-DD%' THEN
    RAISE EXCEPTION 'FAIL guards [Datum kaputt]: %', r; END IF;
  RAISE NOTICE 'PASS reconcile guards [Sentinel/fehlender Key/Zahl/Datum -> ok:false, kein Absturz]';
END $$;

-- Rennen/Pass-2-Ablehnung (Paket DB-ist-das-Gesetz, vorher RAISE = Owner-Alarm): Pass 1 prueft gegen den Altstand;
-- aendert sich ein Konto bis Pass 2, lehnt fn_reconcile_account dort ab. In einer Test-TX nicht natuerlich erreichbar
-- -> fn_reconcile_account wird IN DIESER TX (ROLLBACK unten stellt sie wieder her) fuer das zweite Konto auf
-- {ok:false} umgebogen. Erwartet: {ok:false, reason, account_name}, der GANZE Stapel zurueckgerollt (auch Konto 1).
CREATE OR REPLACE FUNCTION finance.fn_reconcile_account(p jsonb) RETURNS jsonb LANGUAGE plpgsql AS $f$
BEGIN
    IF (SELECT name FROM finance.accounts WHERE id = (p->>'account_id')::int) = '__rca_b__' THEN
        RETURN jsonb_build_object('ok', false, 'reason', 'changed meanwhile');
    END IF;
    UPDATE finance.accounts SET last_reconciled_at = core.fn_today() WHERE id = (p->>'account_id')::int;
    RETURN jsonb_build_object('ok', true);
END $f$;

DO $$
DECLARE r jsonb; v_a int; v_at date;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__rca_a__","account_type":"cash","opening_balance":100}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account('{"name":"__rca_b__","account_type":"cash","opening_balance":50}'::jsonb);
  r := finance.fn_reconcile_accounts(jsonb_build_object('accounts', jsonb_build_array(
         jsonb_build_object('account_name', '__rca_a__', 'confirmed_balance', 120),
         jsonb_build_object('account_name', '__rca_b__', 'confirmed_balance', 60))));
  SELECT last_reconciled_at INTO v_at FROM finance.accounts WHERE id = v_a;
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'account_name' IS DISTINCT FROM '__rca_b__' OR v_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL reconcile batch [Pass-2-Ablehnung -> ok:false, nichts geschrieben]: % / %', r, v_at; END IF;
  RAISE NOTICE 'PASS reconcile batch [Pass-2-Ablehnung als Daten, Stapel zurueckgerollt]';
END $$;

ROLLBACK;
