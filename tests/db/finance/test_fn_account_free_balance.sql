-- tests/db/finance/test_fn_account_free_balance.sql
-- finance.fn_account_free_balance: Saldo eines saldo-basierten Kontos minus die Anteile AKTIVER Sparziele darauf
-- (getaggte Buchungen + Zuordnungen, savings_goal_account_share). Die eine Adresse fuer den Freier-Saldo-Guard
-- (fn_book_savings_reservation, fn_create_savings_goal).
--   (1) ohne Ziel-Anteil = Saldo
--   (2) Zuordnung 1200 + getaggte 300 -> Saldo - 1500
--   (3) abgebrochenes Ziel zaehlt nicht
--   (4) Depot -> NULL (kein Saldo-Konto)
BEGIN;
DO $$
DECLARE v_acct int; v_g1 int; v_g2 int; v_settle int; v_depot int; v_free numeric;
BEGIN
  v_acct := (finance.fn_create_account('{"name":"__afb_acct__","account_type":"cash","opening_balance":5000}'::jsonb)->>'account_id')::int;
  -- (1)
  v_free := finance.fn_account_free_balance(v_acct);
  IF v_free IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 'FAIL afb [1]: %', v_free; END IF;
  -- (2)
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__afb g1__', 9000, current_date + 100, 'active') RETURNING id INTO v_g1;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__afb g2__', 9000, current_date + 100, 'active') RETURNING id INTO v_g2;
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind) VALUES (v_g1, v_acct, 1200, 'EUR', 'manual');
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
    VALUES (v_acct, 300, current_date, 'transfer', v_g2, gen_random_uuid());
  v_free := finance.fn_account_free_balance(v_acct);
  IF v_free IS DISTINCT FROM 3800 THEN RAISE EXCEPTION 'FAIL afb [2]: erwartet 5300 - 1500 = 3800, got %', v_free; END IF;
  -- (3)
  UPDATE finance.savings_goals SET status = 'cancelled' WHERE id = v_g1;
  v_free := finance.fn_account_free_balance(v_acct);
  IF v_free IS DISTINCT FROM 5000 THEN RAISE EXCEPTION 'FAIL afb [3]: erwartet 5300 - 300 = 5000, got %', v_free; END IF;
  -- (3b) ein NEGATIVER Anteil (z. B. Alt-Tag eines Sparplan-Kaufs) erhoeht den freien Saldo nicht (je Ziel bei 0 gekappt)
  INSERT INTO finance.savings_goal_reserve_entries (savings_goal_id, account_id, delta_native, currency, kind) VALUES (v_g2, v_acct, -2000, 'EUR', 'void');
  v_free := finance.fn_account_free_balance(v_acct);
  IF v_free IS DISTINCT FROM 5300 THEN RAISE EXCEPTION 'FAIL afb [3b]: erwartet 5300 (Anteil -1700 zaehlt 0), got %', v_free; END IF;
  IF (SELECT reserved FROM finance.account_reserve_status WHERE account_id = v_acct) IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL afb [3b reserve_status]: negativer Anteil darf reserved nicht senken'; END IF;
  -- (4)
  v_settle := (finance.fn_create_account('{"name":"__afb_settle__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_depot  := (finance.fn_create_account(jsonb_build_object('name','__afb_depot__','account_type','stocks_depot','settlement_id',v_settle))->>'account_id')::int;
  IF finance.fn_account_free_balance(v_depot) IS NOT NULL THEN RAISE EXCEPTION 'FAIL afb [4]: Depot muss NULL liefern'; END IF;
  RAISE NOTICE 'PASS fn_account_free_balance [Saldo, minus aktive Anteile, abgebrochen frei, Depot NULL]';
END $$;
ROLLBACK;
