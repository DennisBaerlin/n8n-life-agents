-- tests/db/finance/test_fn_book_transfer.sql
-- Testet fn_book_transfer: zwei Transaktionen (Soll/Haben) + Balance-Trigger korrekt
BEGIN;

DO $$
DECLARE
  v_result    JSONB;
  v_from_id   INT;
  v_to_id     INT;
  v_amount    NUMERIC := 500;
  v_bal_from  NUMERIC;
  v_bal_to    NUMERIC;
  v_debit_id  INT;
  v_credit_id INT;
BEGIN

  -- Voraussetzungen: zwei Cash-Konten
  SELECT finance.fn_create_account(
    '{"name":"__test_tf_from__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_from_id := (v_result->>'account_id')::int;

  SELECT finance.fn_create_account(
    '{"name":"__test_tf_to__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb
  ) INTO v_result;
  v_to_id := (v_result->>'account_id')::int;

  -- Transfer buchen
  SELECT finance.fn_book_transfer(
    jsonb_build_object(
      'from_account_id',   v_from_id,
      'to_account_id',     v_to_id,
      'amount',            v_amount,
      'transaction_date',  CURRENT_DATE::text,
      'from_account_name', '__test_tf_from__',
      'to_account_name',   '__test_tf_to__'
    )
  ) INTO v_result;

  IF NOT (v_result ? 'debit_tx_id') OR NOT (v_result ? 'credit_tx_id') THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: debit_tx_id oder credit_tx_id fehlt, got %', v_result;
  END IF;
  v_debit_id  := (v_result->>'debit_tx_id')::int;
  v_credit_id := (v_result->>'credit_tx_id')::int;

  -- Assert: from-Balance = -amount (Trigger)
  SELECT finance.fn_get_balance(v_from_id) INTO v_bal_from;
  IF v_bal_from IS DISTINCT FROM -v_amount THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: from-Balance sollte %, got %', -v_amount, v_bal_from;
  END IF;

  -- Assert: to-Balance = +amount (Trigger)
  SELECT finance.fn_get_balance(v_to_id) INTO v_bal_to;
  IF v_bal_to IS DISTINCT FROM v_amount THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: to-Balance sollte %, got %', v_amount, v_bal_to;
  END IF;

  -- Assert: beide Txns haben category=transfer
  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_debit_id AND category = 'transfer' AND amount = -v_amount
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: Debit-Txn nicht korrekt (id=%)', v_debit_id;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM finance.transactions
    WHERE id = v_credit_id AND category = 'transfer' AND amount = v_amount
  ) THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer: Credit-Txn nicht korrekt (id=%)', v_credit_id;
  END IF;

  -- Assert: Post-State-Vertrag — from_balance/to_balance im Return
  IF (v_result->>'from_balance')::numeric IS DISTINCT FROM v_bal_from THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [return from_balance]: erwartet %, got %', v_bal_from, v_result->>'from_balance';
  END IF;
  IF (v_result->>'to_balance')::numeric IS DISTINCT FROM v_bal_to THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [return to_balance]: erwartet %, got %', v_bal_to, v_result->>'to_balance';
  END IF;

  RAISE NOTICE 'PASS fn_book_transfer: from_bal=%, to_bal=%, debit_id=%, credit_id=%',
    v_bal_from, v_bal_to, v_debit_id, v_credit_id;

  -- Korrigierbar: gleiches Konto -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from_id, 'to_account_id', v_from_id, 'amount', 100,
    'transaction_date', CURRENT_DATE::text, 'from_account_name', 'x', 'to_account_name', 'x'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [same account]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [same account -> ok:false]';

  -- Korrigierbar: amount <= 0 -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from_id, 'to_account_id', v_to_id, 'amount', 0,
    'transaction_date', CURRENT_DATE::text, 'from_account_name', 'a', 'to_account_name', 'b'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [amount<=0 -> ok:false]';

END $$;

-- ============================================================
-- Cross-Currency (Multi-Waehrung): je Bein in Native-Waehrung, to_amount Pflicht, fx_rate gespeichert.
-- ============================================================
DO $$
DECLARE
  v_result  JSONB;
  v_clp     INT;
  v_eur     INT;
  v_bal_clp NUMERIC;
  v_bal_eur NUMERIC;
  v_debit   INT;
  v_fx      NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_tf_clp__","account_type":"cash","currency":"CLP"}'::jsonb) INTO v_result;
  v_clp := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_tf_eur__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_eur := (v_result->>'account_id')::int;

  -- 1.450.000 CLP -> 1000 EUR (Nutzer bestaetigt beide Betraege)
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_clp, 'to_account_id', v_eur,
    'from_amount', 1450000, 'to_amount', 1000,
    'transaction_date', CURRENT_DATE::text,
    'from_account_name','__test_tf_clp__','to_account_name','__test_tf_eur__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL xccy transfer: erwartet ok=true, got %', v_result;
  END IF;
  v_debit := (v_result->>'debit_tx_id')::int;

  SELECT finance.fn_get_balance(v_clp) INTO v_bal_clp;
  SELECT finance.fn_get_balance(v_eur) INTO v_bal_eur;
  IF v_bal_clp IS DISTINCT FROM -1450000 THEN RAISE EXCEPTION 'FAIL xccy: CLP-Saldo % erwartet -1450000', v_bal_clp; END IF;
  IF v_bal_eur IS DISTINCT FROM 1000      THEN RAISE EXCEPTION 'FAIL xccy: EUR-Saldo % erwartet 1000', v_bal_eur; END IF;

  -- Assert: Post-State-Vertrag — native Salden beider Beine im Return (Cross-Currency)
  IF (v_result->>'from_balance')::numeric IS DISTINCT FROM v_bal_clp THEN
    RAISE EXCEPTION 'FAIL xccy [return from_balance]: erwartet %, got %', v_bal_clp, v_result->>'from_balance';
  END IF;
  IF (v_result->>'to_balance')::numeric IS DISTINCT FROM v_bal_eur THEN
    RAISE EXCEPTION 'FAIL xccy [return to_balance]: erwartet %, got %', v_bal_eur, v_result->>'to_balance';
  END IF;

  SELECT fx_rate INTO v_fx FROM finance.transactions WHERE id = v_debit;
  IF v_fx IS DISTINCT FROM ROUND(1000.0/1450000.0, 10) THEN
    RAISE EXCEPTION 'FAIL xccy: fx_rate % erwartet %', v_fx, ROUND(1000.0/1450000.0, 10);
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [cross-currency CLP->EUR]';

  -- Cross-Currency ohne to_amount -> {ok:false}
  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_clp, 'to_account_id', v_eur, 'from_amount', 500000,
    'transaction_date', CURRENT_DATE::text,
    'from_account_name','__test_tf_clp__','to_account_name','__test_tf_eur__'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL xccy [missing to_amount]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [cross-currency ohne to_amount -> ok:false]';
END $$;

-- ============================================================
-- WS-C2 Reserve-Waechter: ein Transfer raus aus einem Reserve-haltenden Konto drueckt dessen Saldo unter die
-- getaggte Reserve -> fn faltet reserve_breach NUR fuers Soll-(from-)Bein (das Haben-Bein erhoeht das Zielkonto).
-- ============================================================
DO $$
DECLARE
  v_result JSONB; v_from INT; v_to INT; v_goal INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__tf_rb_from__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result; v_from := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__tf_rb_to__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_result; v_to := (v_result->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tf_rb_goal__', 9000, current_date + 365, 'active') RETURNING id INTO v_goal;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_from, 600, current_date - 10, 'transfer', v_goal, gen_random_uuid());   -- Reserve auf dem Quell-Konto: Saldo 600, reserviert 600

  SELECT finance.fn_book_transfer(jsonb_build_object(
    'from_account_id', v_from, 'to_account_id', v_to, 'amount', 500,
    'transaction_date', CURRENT_DATE::text, 'from_account_name','__tf_rb_from__','to_account_name','__tf_rb_to__'
  )) INTO v_result;
  -- from-Saldo 100 < reserviert 600 -> reserve_breach fuers from-Konto, shortfall 500.
  IF NOT (v_result ? 'reserve_breach') OR (v_result->'reserve_breach'->>'account_id')::int IS DISTINCT FROM v_from
     OR (v_result->'reserve_breach'->>'shortfall')::numeric IS DISTINCT FROM 500 THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [reserve_breach]: erwartet reserve_breach fuers from-Konto shortfall 500, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS fn_book_transfer [reserve_breach: Transfer raus aus Reserve-Konto -> from-Breach shortfall 500]';
END $$;

-- ---------- Befund 2026-11-03: Bein im Startbetrag eines Kontos: Ablehnung ohne Write; internes Flag bucht nur das andere Bein ----------
DO $$
DECLARE
  T DATE := core.fn_today();
  v_old INT; v_late INT; v_late2 INT; v_today INT; v_rb INT; v_goal INT; v_r JSONB; v_n INT;
BEGIN
  v_old  := (finance.fn_create_account(jsonb_build_object('name','__tf_ob_old__','account_type','cash','currency','EUR','opening_balance',5000,'opening_balance_date',(T-120)::text))->>'account_id')::int;
  v_late := (finance.fn_create_account(jsonb_build_object('name','__tf_ob_late__','account_type','cash','currency','EUR','opening_balance',300,'opening_balance_date',(T-20)::text))->>'account_id')::int;
  v_late2 := (finance.fn_create_account(jsonb_build_object('name','__tf_ob_late2__','account_type','cash','currency','EUR','opening_balance',300,'opening_balance_date',(T-20)::text))->>'account_id')::int;
  v_today := (finance.fn_create_account(jsonb_build_object('name','__tf_ob_today__','account_type','cash','currency','EUR','opening_balance',300,'opening_balance_date',T::text))->>'account_id')::int;

  -- Ziel im Startbetrag
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_old,'to_account_id',v_late,'amount',100,'transaction_date',(T-25)::text,
           'from_account_name','__tf_ob_old__','to_account_name','__tf_ob_late__'));
  IF v_r->>'code' IS DISTINCT FROM 'before_opening' OR (v_r->>'ok')::boolean IS DISTINCT FROM false
     OR position('__tf_ob_late__' IN v_r->>'reason') = 0 OR position((T-20)::text IN v_r->>'reason') = 0 THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [before_opening Ziel]: %', v_r; END IF;
  -- Quelle im Startbetrag (am Stichtag selbst)
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_late,'to_account_id',v_old,'amount',100,'transaction_date',(T-20)::text,
           'from_account_name','__tf_ob_late__','to_account_name','__tf_ob_old__'));
  IF v_r->>'code' IS DISTINCT FROM 'before_opening' THEN RAISE EXCEPTION 'FAIL fn_book_transfer [before_opening Quelle]: %', v_r; END IF;
  -- relatives Datum
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_old,'to_account_id',v_today,'amount',100,'transaction_date','yesterday',
           'from_account_name','__tf_ob_old__','to_account_name','__tf_ob_today__'));
  IF v_r->>'code' IS DISTINCT FROM 'before_opening' THEN RAISE EXCEPTION 'FAIL fn_book_transfer [before_opening relativ]: %', v_r; END IF;
  SELECT count(*) INTO v_n FROM finance.transactions WHERE account_id IN (v_old, v_late, v_today) AND category = 'transfer';
  IF v_n <> 0 THEN RAISE EXCEPTION 'FAIL fn_book_transfer [before_opening kein Write]: % Beine', v_n; END IF;
  -- Tag nach dem Stichtag bzw. am Anlagetag: normal zwei Beine
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_old,'to_account_id',v_late,'amount',10,'transaction_date',(T-19)::text,
           'from_account_name','__tf_ob_old__','to_account_name','__tf_ob_late__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'credit_tx_id') IS NULL THEN RAISE EXCEPTION 'FAIL fn_book_transfer [nach dem Stichtag]: %', v_r; END IF;
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_old,'to_account_id',v_today,'amount',10,'transaction_date',T::text,
           'from_account_name','__tf_ob_old__','to_account_name','__tf_ob_today__'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL fn_book_transfer [Anlagetag selbst]: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_book_transfer [before_opening: beide Richtungen, relativ, kein Write]';

  -- Flag: Ziel-Bein im Startbetrag -> nur Soll, Zahlen je Rueckgabefeld; auch bei schon abgeglichenem Ziel
  PERFORM finance.fn_reconcile_account(jsonb_build_object('account_id',v_late2,'confirmed_balance',300,'reconciliation_date',(T-5)::text));
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_old,'to_account_id',v_late2,'amount',100,'transaction_date',(T-25)::text,
           'from_account_name','__tf_ob_old__','to_account_name','__tf_ob_late2__','skip_opening_leg','true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'debit_tx_id') IS NULL OR (v_r->>'credit_tx_id') IS NOT NULL
     OR (v_r->>'from_balance')::numeric IS DISTINCT FROM 4880 OR (v_r->>'to_balance') IS NOT NULL
     OR EXISTS (SELECT 1 FROM finance.transactions WHERE account_id = v_late2 AND category = 'transfer') THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [Flag Ziel]: %', v_r; END IF;
  -- Flag: Quell-Bein im Startbetrag -> nur Haben
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_late,'to_account_id',v_old,'amount',50,'transaction_date',(T-25)::text,
           'from_account_name','__tf_ob_late__','to_account_name','__tf_ob_old__','skip_opening_leg','true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'debit_tx_id') IS NOT NULL OR (v_r->>'credit_tx_id') IS NULL
     OR (v_r->>'from_balance') IS NOT NULL OR (v_r->>'to_balance')::numeric IS DISTINCT FROM 4930
     OR (SELECT balance FROM finance.account_balances WHERE account_id = v_late) IS DISTINCT FROM 310 THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [Flag Quelle]: %', v_r; END IF;
  -- Flag: beide Beine im Startbetrag -> Ablehnung ohne Write
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_late,'to_account_id',v_late2,'amount',50,'transaction_date',(T-25)::text,
           'from_account_name','__tf_ob_late__','to_account_name','__tf_ob_late2__','skip_opening_leg','true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM false OR v_r->>'code' IS DISTINCT FROM 'before_opening' THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [Flag beide Beine]: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_book_transfer [skip_opening_leg: je ein Bein, Rueckgabe NULL fuers nicht gebuchte, beide -> Ablehnung]';

  -- Flag: Soll-Bein nicht gebucht -> kein Reserve-Hinweis fuer das unberuehrte Konto (Kontrolle: mit Soll-Bein kommt er)
  v_rb := (finance.fn_create_account(jsonb_build_object('name','__tf_ob_rb__','account_type','cash','currency','EUR','opening_balance',600,'opening_balance_date',(T-20)::text))->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__tf_ob_rb_goal__', 9000, T + 365, 'active') RETURNING id INTO v_goal;
  -- Reserve 900 auf dem Konto, Stand 800 (600 + 900 - 700): Luecke besteht schon; Direkt-INSERT beruehrt den Melde-Latch nicht
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_rb, 900, T - 10, 'transfer', v_goal, gen_random_uuid());
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_rb, -700, T - 9, 'other');
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_rb,'to_account_id',v_old,'amount',1,'transaction_date',(T-25)::text,
           'from_account_name','__tf_ob_rb__','to_account_name','__tf_ob_old__','skip_opening_leg','true'));
  IF (v_r->>'ok')::boolean IS DISTINCT FROM true OR (v_r->>'debit_tx_id') IS NOT NULL OR v_r ? 'reserve_breach' THEN
    RAISE EXCEPTION 'FAIL fn_book_transfer [Flag ohne Soll-Bein: kein reserve_breach]: %', v_r; END IF;
  v_r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_rb,'to_account_id',v_old,'amount',1,'transaction_date',(T-1)::text,
           'from_account_name','__tf_ob_rb__','to_account_name','__tf_ob_old__'));
  IF NOT (v_r ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL fn_book_transfer [Kontrolle reserve_breach mit Soll-Bein]: %', v_r; END IF;
  RAISE NOTICE 'PASS fn_book_transfer [Reserve-Waechter nur mit gebuchtem Soll-Bein]';
END $$;

-- Betrag als deutscher Text: "1.234,56" wird gebucht, Unlesbares -> {ok:false} statt Cast-Fehler (Owner-Alarm).
DO $$
DECLARE r jsonb; v_a int; v_b int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_bt_de_a__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__t_bt_de_b__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_a,'to_account_id',v_b,'amount','1.234,56'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR finance.fn_get_balance(v_b) IS DISTINCT FROM 1234.56 THEN
    RAISE EXCEPTION 'FAIL book_transfer ["1.234,56" -> 1234.56]: % / %', r, finance.fn_get_balance(v_b); END IF;
  r := finance.fn_book_transfer(jsonb_build_object('from_account_id',v_a,'to_account_id',v_b,'amount','etwa hundert'));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL book_transfer [unlesbar -> ok:false]: %', r; END IF;
  RAISE NOTICE 'PASS book_transfer [deutscher Betrag, unlesbar -> ok:false]';
END $$;

ROLLBACK;
