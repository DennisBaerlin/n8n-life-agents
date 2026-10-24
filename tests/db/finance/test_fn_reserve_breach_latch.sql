-- tests/db/finance/test_fn_reserve_breach_latch.sql
-- Phase Notify (WS-2): der reserve_breach-Write-Time-Fold ist jetzt ueber die geteilte Dedup-Schicht
-- gelatcht (core.notification_state, key 'reserve_breach:<account_id>'). Pin der NEUEN Mechanik:
--   (a) erster un-getaggter Outflow unter die Reserve  -> faltet reserve_breach (Flanke ok->fired)
--   (b) zweiter Outflow unter demselben Latch           -> faltet NICHT (still)
--   (c) un-getaggter Inflow hebt Saldo >= reserved      -> Saldo-Trigger re-armt den Latch
--   (d) erneuter Outflow unter die Reserve              -> faltet WIEDER (Re-Arm griff)
--   (e) suppress-Pfad (fn_book_savings_goal_transfer)   -> meldet NICHT und vergiftet den Latch NICHT
-- BEGIN...ROLLBACK -> kein Residual-State (auch core.notification_state rollt zurueck).
BEGIN;

DO $$
DECLARE v_res JSONB; v_a INT; v_g INT;
BEGIN
  -- Konto A mit Reserve 600 (getaggt) -> Saldo 600, reserviert 600 (kein Breach: gleich).
  SELECT finance.fn_create_account('{"name":"__rbl_a__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_a := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rbl_g__', 9000, current_date + 365, 'active') RETURNING id INTO v_g;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_a, 600, current_date - 10, 'transfer', v_g, gen_random_uuid());

  -- (a) erster un-getaggter Outflow -100 -> Saldo 500 < 600 -> Flanke -> reserve_breach gefaltet
  SELECT finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','100','direction','outflow','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF NOT (v_res ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL [a]: erster Breach muss falten, got %', v_res; END IF;

  -- (b) zweiter un-getaggter Outflow -50 -> Saldo 450 < 600 -> Latch fired -> KEIN Fold
  SELECT finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','50','direction','outflow','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF v_res ? 'reserve_breach' THEN RAISE EXCEPTION 'FAIL [b]: zweiter Breach unter Latch darf NICHT falten, got %', v_res; END IF;

  -- (c) un-getaggter Inflow +200 -> Saldo 650 >= 600 -> Saldo-Trigger re-armt (Inflow faltet nie)
  SELECT finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','200','direction','inflow','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF v_res ? 'reserve_breach' THEN RAISE EXCEPTION 'FAIL [c]: Inflow faltet nie, got %', v_res; END IF;

  -- (d) dritter un-getaggter Outflow -150 -> Saldo 500 < 600 -> Latch re-armed -> faltet WIEDER
  SELECT finance.fn_book_transaction(jsonb_build_object('account_id',v_a,'amount','150','direction','outflow','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF NOT (v_res ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL [d]: nach Re-Arm muss erneuter Breach falten, got %', v_res; END IF;

  RAISE NOTICE 'PASS reserve_breach-Latch [a fold, b suppress, c re-arm via Inflow, d re-fold]';
END $$;

-- ============================================================
-- (e) Suppress-Pfad: fn_book_savings_goal_transfer ruft fn_book_transfer intern mit suppress_breach=true.
--   Eine getaggte Einzahlung von einem Funding-Konto mit EIGENER Reserve breacht das Funding-Konto, darf aber
--   (1) keine Note falten UND (2) den Latch NICHT setzen -> ein spaeterer echter un-getaggter Breach faltet.
-- ============================================================
DO $$
DECLARE v_res JSONB; v_f INT; v_r INT; v_gf INT; v_gr INT;
BEGIN
  SELECT finance.fn_create_account('{"name":"__rbl_f__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_f := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account('{"name":"__rbl_r__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res; v_r := (v_res->>'account_id')::int;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rbl_gf__', 9000, current_date + 365, 'active') RETURNING id INTO v_gf;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__rbl_gr__', 9000, current_date + 365, 'active') RETURNING id INTO v_gr;
  -- F: eigene Reserve 500 (getaggt) -> Saldo 500, reserviert 500.
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_f, 500, current_date - 10, 'transfer', v_gf, gen_random_uuid());

  -- Sparziel-Einzahlung 300 von F nach R (Ziel gr): F debit -300 UN-getaggt -> F Saldo 200 < reserviert 500
  -- -> breacht F, ABER suppress_breach -> KEINE Note, Latch F NICHT gesetzt.
  SELECT finance.fn_book_savings_goal_transfer(jsonb_build_object(
    'savings_goal_id',v_gr,'from_account_id',v_f,'to_account_id',v_r,'amount',300,'direction','deposit','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF v_res ? 'reserve_breach' THEN RAISE EXCEPTION 'FAIL [e]: getaggte Sparziel-Bewegung darf kein reserve_breach falten, got %', v_res; END IF;

  -- jetzt ein normaler un-getaggter Outflow -10 auf F -> F Saldo 190 < 500 -> breacht -> Latch war NICHT
  -- vergiftet -> faltet (Flanke). Vergifteter Latch wuerde hier still bleiben (Bug).
  SELECT finance.fn_book_transaction(jsonb_build_object('account_id',v_f,'amount','10','direction','outflow','transaction_date',CURRENT_DATE::text)) INTO v_res;
  IF NOT (v_res ? 'reserve_breach') THEN RAISE EXCEPTION 'FAIL [e2]: suppress-Pfad hat den Latch vergiftet (kein Fold beim ersten echten Breach), got %', v_res; END IF;

  RAISE NOTICE 'PASS reserve_breach-Latch [e: suppress-Pfad meldet nicht UND vergiftet den Latch nicht]';
END $$;

ROLLBACK;
