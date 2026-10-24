-- tests/db/finance/test_fn_book_recurring_transfer.sql
-- WS-2 (Multi-Member): wiederkehrender interner Transfer.
--   1. fn_create_recurring_transfer: legt eine Transfer-rp an (amount NEGATIV = Quell-Sicht,
--      account_id=Quelle, target_account_id=Ziel); from<>to via {ok:false} (CHECK = Backstop).
--   2. fn_book_recurring_transfer: bucht zwei Beine (Soll -/Haben +, category=transfer, eine group_id,
--      beide Beine tragen recurring_payment_id) + Idempotenz-Guard je (rp_id, due_date).
--   3. fn_book_recurring_occurrence delegiert fuer Transfer-rps an fn_book_recurring_transfer
--      (Zwei-Bein-Invariante am fn-Layer, nicht am Cron-Canvas — der Scheduler bucht korrekt).
--   4. Cross-Currency: Ziel-Bein wird ueber EUR-Cross (fx_rates) konvertiert (DB rechnet, kein Nutzer-Input je Vorkommen).
BEGIN;

-- ============================================================
-- 1+2+3: Same-currency Transfer (Owner-Konto -> Kind-Depot-Cash), Buchung, Idempotenz, Delegation
-- ============================================================
DO $$
DECLARE
  v_result  JSONB;
  v_from    INT;
  v_to      INT;
  v_rp      INT;
  v_due     DATE := '2026-05-01';
  v_debit   INT;
  v_credit  INT;
  v_group   UUID;
  v_bal_from NUMERIC;
  v_bal_to   NUMERIC;
  v_me      NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rt_src__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb) INTO v_result;
  v_from := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_rt_dst__","account_type":"cash","account_holder":"Test","currency":"EUR"}'::jsonb) INTO v_result;
  v_to := (v_result->>'account_id')::int;

  -- create: 200 EUR/Monat von src nach dst
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','Top-up Kind-Depot', 'from_account_id', v_from, 'to_account_id', v_to,
    'amount', 200, 'schedule_unit','month', 'schedule_day_of_month', 1,
    'first_payment_date','2026-05-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [create]: erwartet ok=true, got %', v_result;
  END IF;
  v_rp := (v_result->>'recurring_payment_id')::int;

  -- gespeichert: amount NEGATIV (Quell-Sicht), target gesetzt, monthly_equivalent = -200
  IF NOT EXISTS (SELECT 1 FROM finance.recurring_payments
                 WHERE id = v_rp AND account_id = v_from AND target_account_id = v_to AND amount = -200) THEN
    RAISE EXCEPTION 'FAIL [create]: rp-Spalten nicht korrekt (id=%)', v_rp;
  END IF;
  v_me := (v_result->>'monthly_equivalent')::numeric;
  IF v_me IS DISTINCT FROM -200 THEN
    RAISE EXCEPTION 'FAIL [create]: monthly_equivalent erwartet -200, got %', v_me;
  END IF;
  RAISE NOTICE 'PASS [create]: rp=% (amount=-200, target=%)', v_rp, v_to;

  -- book via fn_book_recurring_occurrence -> muss an fn_book_recurring_transfer delegieren (zwei Beine)
  SELECT finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [book via occurrence/delegation]: erwartet ok=true, got %', v_result;
  END IF;
  IF NOT (v_result ? 'debit_tx_id') OR NOT (v_result ? 'credit_tx_id') THEN
    RAISE EXCEPTION 'FAIL [delegation]: erwartet Zwei-Bein-Return (debit/credit_tx_id), got %', v_result;
  END IF;
  v_debit  := (v_result->>'debit_tx_id')::int;
  v_credit := (v_result->>'credit_tx_id')::int;

  -- Soll-Bein: -200 auf Quelle, category=transfer, recurring_payment_id gesetzt
  IF NOT EXISTS (SELECT 1 FROM finance.transactions
                 WHERE id = v_debit AND account_id = v_from AND amount = -200
                   AND category = 'transfer' AND transaction_date = v_due AND recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [book]: Soll-Bein nicht korrekt (id=%)', v_debit;
  END IF;
  -- Haben-Bein: +200 auf Ziel, category=transfer, recurring_payment_id gesetzt
  IF NOT EXISTS (SELECT 1 FROM finance.transactions
                 WHERE id = v_credit AND account_id = v_to AND amount = 200
                   AND category = 'transfer' AND transaction_date = v_due AND recurring_payment_id = v_rp) THEN
    RAISE EXCEPTION 'FAIL [book]: Haben-Bein nicht korrekt (id=%)', v_credit;
  END IF;
  -- gemeinsame group_id (Multi-Leg)
  SELECT group_id INTO v_group FROM finance.transactions WHERE id = v_debit;
  IF v_group IS NULL OR v_group IS DISTINCT FROM (SELECT group_id FROM finance.transactions WHERE id = v_credit) THEN
    RAISE EXCEPTION 'FAIL [book]: Beine teilen keine group_id (debit=%, credit=%)', v_debit, v_credit;
  END IF;

  -- Salden via Trigger: Quelle -200, Ziel +200 (cashflow-neutral im Haushalt)
  SELECT finance.fn_get_balance(v_from) INTO v_bal_from;
  SELECT finance.fn_get_balance(v_to)   INTO v_bal_to;
  IF v_bal_from IS DISTINCT FROM -200 OR v_bal_to IS DISTINCT FROM 200 THEN
    RAISE EXCEPTION 'FAIL [book balance]: erwartet -200/+200, got %/%', v_bal_from, v_bal_to;
  END IF;
  RAISE NOTICE 'PASS [book/delegation]: debit=%, credit=%, group=%', v_debit, v_credit, v_group;

  -- Idempotenz: erneut buchen (direkt) -> {ok:false}, kein drittes/viertes Bein
  SELECT finance.fn_book_recurring_transfer(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false OR v_result->>'code' IS DISTINCT FROM 'already_booked' THEN
    RAISE EXCEPTION 'FAIL [double book]: erwartet ok=false + code=already_booked, got %', v_result;
  END IF;
  IF (SELECT count(*) FROM finance.transactions WHERE recurring_payment_id = v_rp AND transaction_date = v_due) <> 2 THEN
    RAISE EXCEPTION 'FAIL [double book]: zusaetzliche Beine gebucht';
  END IF;
  RAISE NOTICE 'PASS [double book -> ok:false, weiter genau 2 Beine]';
END $$;

-- ============================================================
-- 4: Korrigierbare Faelle — Selbst-Transfer ({ok:false}, CHECK = Backstop) + not-a-transfer-Guard
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_acct   INT;
  v_rp     INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rt_self__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_acct := (v_result->>'account_id')::int;

  -- Selbst-Transfer (from==to) -> {ok:false}, kein Write
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','self', 'from_account_id', v_acct, 'to_account_id', v_acct,
    'amount', 50, 'schedule_unit','month', 'first_payment_date','2026-05-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [self transfer]: erwartet ok=false, got %', v_result;
  END IF;
  IF EXISTS (SELECT 1 FROM finance.recurring_payments WHERE account_id = v_acct AND target_account_id = v_acct) THEN
    RAISE EXCEPTION 'FAIL [self transfer]: Zeile wurde trotzdem geschrieben';
  END IF;
  RAISE NOTICE 'PASS [self transfer -> ok:false, kein Write]';

  -- amount <= 0 -> {ok:false}
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','zero', 'from_account_id', v_acct, 'to_account_id', v_acct,
    'amount', 0, 'schedule_unit','month', 'first_payment_date','2026-05-01'
  )) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [amount<=0]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [amount<=0 -> ok:false]';

  -- not-a-transfer: fn_book_recurring_transfer auf einer rp OHNE target -> {ok:false}
  v_rp := finance.fn_add_recurring_payment(v_acct, -100, 'plain', 1::smallint, 'month'::finance.schedule_unit,
                                           NULL, '2026-05-01', '2026-05-01', NULL, NULL, NULL);
  SELECT finance.fn_book_recurring_transfer(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', '2026-05-01')) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [not a transfer]: erwartet ok=false, got %', v_result;
  END IF;
  RAISE NOTICE 'PASS [not a transfer -> ok:false]';
END $$;

-- ============================================================
-- 5: Cross-Currency (EUR -> KRW): Ziel-Bein ueber EUR-Cross konvertiert, fx_rate auf beiden Beinen
-- ============================================================
DO $$
DECLARE
  v_result  JSONB;
  v_eur     INT;
  v_krw     INT;
  v_rp      INT;
  v_due     DATE := '2026-06-01';
  v_credit  INT;
  v_bal_krw NUMERIC;
  v_fx      NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rt_eur__","account_type":"cash","currency":"EUR"}'::jsonb) INTO v_result;
  v_eur := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_rt_krw__","account_type":"cash","currency":"KRW"}'::jsonb) INTO v_result;
  v_krw := (v_result->>'account_id')::int;

  -- EZB-Kurs EUR->KRW: 1 EUR = 1450 KRW
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of)
  VALUES ('EUR','KRW', 1450, '2026-01-01')
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','EUR->KRW', 'from_account_id', v_eur, 'to_account_id', v_krw,
    'amount', 100, 'schedule_unit','month', 'first_payment_date','2026-06-01'
  )) INTO v_result;
  v_rp := (v_result->>'recurring_payment_id')::int;

  SELECT finance.fn_book_recurring_transfer(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [xccy book]: erwartet ok=true, got %', v_result;
  END IF;
  v_credit := (v_result->>'credit_tx_id')::int;

  -- Ziel-Bein: +145000 KRW (100 EUR * 1450)
  SELECT finance.fn_get_balance(v_krw) INTO v_bal_krw;
  IF v_bal_krw IS DISTINCT FROM 145000 THEN
    RAISE EXCEPTION 'FAIL [xccy]: KRW-Saldo % erwartet 145000', v_bal_krw;
  END IF;
  -- Quelle: -100 EUR
  IF finance.fn_get_balance(v_eur) IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL [xccy]: EUR-Saldo % erwartet -100', finance.fn_get_balance(v_eur);
  END IF;
  -- fx_rate auf dem Haben-Bein = 145000/100 = 1450
  SELECT fx_rate INTO v_fx FROM finance.transactions WHERE id = v_credit;
  IF v_fx IS DISTINCT FROM ROUND(145000.0/100.0, 10) THEN
    RAISE EXCEPTION 'FAIL [xccy]: fx_rate % erwartet %', v_fx, ROUND(145000.0/100.0, 10);
  END IF;
  RAISE NOTICE 'PASS [cross-currency EUR->KRW]: KRW=+145000, fx=%', v_fx;
END $$;

-- ============================================================
-- 6: Cross-Currency NON-EUR -> NON-EUR (GBP -> KRW): zwei FX-Lookups (Quelle->EUR, EUR->Ziel)
-- ============================================================
DO $$
DECLARE
  v_result  JSONB;
  v_gbp     INT;
  v_krw     INT;
  v_rp      INT;
  v_due     DATE := '2026-07-01';
  v_bal_krw NUMERIC;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rt_gbp__","account_type":"cash","currency":"GBP"}'::jsonb) INTO v_result;
  v_gbp := (v_result->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__test_rt_krw2__","account_type":"cash","currency":"KRW"}'::jsonb) INTO v_result;
  v_krw := (v_result->>'account_id')::int;

  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES
    ('EUR','GBP', 0.8,  '2026-01-01'),
    ('EUR','KRW', 1450, '2026-01-01')
  ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;

  -- 100 GBP -> EUR (100/0.8 = 125 EUR) -> KRW (125*1450 = 181250 KRW)
  SELECT finance.fn_create_recurring_transfer(jsonb_build_object(
    'name','GBP->KRW', 'from_account_id', v_gbp, 'to_account_id', v_krw,
    'amount', 100, 'schedule_unit','month', 'first_payment_date','2026-07-01'
  )) INTO v_result;
  v_rp := (v_result->>'recurring_payment_id')::int;

  SELECT finance.fn_book_recurring_transfer(jsonb_build_object('recurring_payment_id', v_rp, 'due_date', v_due)) INTO v_result;
  IF (v_result->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [GBP->KRW book]: erwartet ok=true, got %', v_result;
  END IF;
  SELECT finance.fn_get_balance(v_krw) INTO v_bal_krw;
  IF v_bal_krw IS DISTINCT FROM ROUND(ROUND(100.0/0.8, 2) * 1450, 2) THEN
    RAISE EXCEPTION 'FAIL [GBP->KRW]: KRW-Saldo % erwartet %', v_bal_krw, ROUND(ROUND(100.0/0.8, 2) * 1450, 2);
  END IF;
  IF finance.fn_get_balance(v_gbp) IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL [GBP->KRW]: GBP-Saldo % erwartet -100', finance.fn_get_balance(v_gbp);
  END IF;
  RAISE NOTICE 'PASS [cross-currency GBP->KRW]: KRW=+181250';

  -- Rundungs-Paket 2026-10-23: nur EINE Rundung am Ende (vorher EUR-Zwischenwert auf Cent, dann x Kurs erneut):
  -- 100 GBP bei 0.83 -> 120.4819277 EUR -> x1450 = 174698.80 KRW (doppelt gerundet waeren es 174696.00).
  DECLARE v_gbp2 INT; v_krw3 INT; v_rp2 INT; BEGIN
    v_gbp2 := (finance.fn_create_account('{"name":"__test_rt_gbp2__","account_type":"cash","currency":"GBP"}'::jsonb)->>'account_id')::int;
    v_krw3 := (finance.fn_create_account('{"name":"__test_rt_krw3__","account_type":"cash","currency":"KRW"}'::jsonb)->>'account_id')::int;
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','GBP', 0.83, '2026-06-30')
    ON CONFLICT (base_currency, quote_currency, as_of) DO UPDATE SET rate = EXCLUDED.rate;
    v_rp2 := (finance.fn_create_recurring_transfer(jsonb_build_object('name','GBP->KRW 2', 'from_account_id', v_gbp2,
      'to_account_id', v_krw3, 'amount', 100, 'schedule_unit','month', 'first_payment_date','2026-07-01'))->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_transfer(jsonb_build_object('recurring_payment_id', v_rp2, 'due_date', '2026-07-01'));
    IF finance.fn_get_balance(v_krw3) IS DISTINCT FROM ROUND(100.0 / 0.83 * 1450, 2) THEN
      RAISE EXCEPTION 'FAIL [GBP->KRW einfach gerundet]: KRW-Saldo % erwartet %', finance.fn_get_balance(v_krw3), ROUND(100.0 / 0.83 * 1450, 2);
    END IF;
  END;
  RAISE NOTICE 'PASS [cross-currency einfach gerundet]: 174698.80 KRW statt 174696.00';
END $$;

-- ============================================================
-- 7: Degenerierter 0-Betrag — seit WS-3a (CHECK amount<>0, V005) STRUKTURELL unmoeglich.
--    Frueher fing fn_book_recurring_transfer einen 0-Betrag (nur via Direkt-SQL anlegbar) per v_mag=0-Guard
--    ab (kein div/0). Jetzt blockt der Tabellen-CHECK die 0-Betrag-rp schon beim INSERT -> die Invariante
--    sitzt am tiefsten Layer (kein doppelter fn-Guard mehr; v_mag>0 ist garantiert -> keine fx_rate-Division
--    durch 0 moeglich). Vollabdeckung des CHECK: tests/db/finance/test_recurring_payment_amount_check.sql.
-- ============================================================
DO $$
DECLARE
  v_result JSONB;
  v_a      INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__test_rt_z0a__","account_type":"cash","currency":"KRW"}'::jsonb) INTO v_result;
  v_a := (v_result->>'account_id')::int;

  BEGIN
    PERFORM finance.fn_add_recurring_payment(v_a, 0, 'zero', 1::smallint, 'month'::finance.schedule_unit,
                                             NULL, '2026-05-01', '2026-05-01', NULL, NULL, NULL);
    RAISE EXCEPTION 'FAIL [zero amount]: 0-Betrag-rp akzeptiert -> CHECK (amount <> 0) fehlt';
  EXCEPTION WHEN check_violation THEN
    RAISE NOTICE 'PASS [zero amount: CHECK blockt die 0-Betrag-Transfer-rp strukturell (v_mag>0 garantiert, kein div/0)]';
  END;
END $$;

ROLLBACK;
