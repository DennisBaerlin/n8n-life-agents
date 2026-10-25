-- tests/db/finance/test_constraints_hardening.sql
-- Strukturelle Haertung (Defense-in-Depth): jeder neue CHECK lehnt die Verletzung ab und laesst
-- gueltige Grenzwerte zu. Prueft die DB-Ebene direkt (umgeht die fn-Guards bewusst).
BEGIN;

DO $$
DECLARE
  v_res JSONB; v_cash INT; v_depot INT; v_hid INT;
BEGIN
  -- Setup
  SELECT finance.fn_create_account('{"name":"__test_chk_cash__","account_type":"cash","account_holder":"Test"}'::jsonb) INTO v_res;
  v_cash := (v_res->>'account_id')::int;
  SELECT finance.fn_create_account(jsonb_build_object('name','__test_chk_depot__','account_type','stocks_depot','account_holder','Test','settlement_id',v_cash)) INTO v_res;
  v_depot := (v_res->>'account_id')::int;
  INSERT INTO finance.depot_holdings (account_id, isin, symbol, name)
  VALUES (v_depot, 'IE00BK5BQT80', 'VWCE', 'Vanguard') RETURNING id INTO v_hid;

  -- shares >= 0: negativ lehnt ab
  BEGIN
    UPDATE finance.depot_holdings SET shares = -1 WHERE id = v_hid;
    RAISE EXCEPTION 'FAIL [shares>=0]: CHECK haette ablehnen muessen';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [shares>=0 lehnt -1 ab]'; END;
  -- shares = 0 (Grenzwert) erlaubt
  UPDATE finance.depot_holdings SET shares = 0 WHERE id = v_hid;
  RAISE NOTICE 'PASS [shares=0 erlaubt]';

  -- (Versicherungs-Beitrag > 0: seit finance:V027 nur an der rp -- dort CHECK amount <> 0, V005.)


  -- original_amount > 0 (status=paused -> active_needs_annuity nicht relevant)
  BEGIN
    INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, status, loan_account_id)
    VALUES ('__test_chk_loan__', 0, CURRENT_DATE, 1.0, 'paused', v_cash);
    RAISE EXCEPTION 'FAIL [original_amount>0]: CHECK haette ablehnen muessen';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [original_amount>0 lehnt 0 ab]'; END;

  -- target_amount > 0
  BEGIN
    INSERT INTO finance.savings_goals (name, target_amount, target_date)
    VALUES ('__test_chk_goal__', 0, CURRENT_DATE);
    RAISE EXCEPTION 'FAIL [target_amount>0]: CHECK haette ablehnen muessen';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [target_amount>0 lehnt 0 ab]'; END;

  -- real_estate.current_value >= 0: negativ lehnt ab, 0/NULL erlaubt
  BEGIN
    INSERT INTO finance.real_estate (name, current_value) VALUES ('__test_chk_re_bad__', -1);
    RAISE EXCEPTION 'FAIL [re.current_value>=0]: CHECK haette ablehnen muessen';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [re.current_value>=0 lehnt -1 ab]'; END;
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__test_chk_re_ok__', 0);
  INSERT INTO finance.real_estate (name, current_value) VALUES ('__test_chk_re_null__', NULL);
  RAISE NOTICE 'PASS [re.current_value 0 und NULL erlaubt]';

  -- pension.current_value >= 0
  BEGIN
    INSERT INTO finance.pension (name, pension_type, current_value)
    VALUES ('__test_chk_pen__', 'private', -1);
    RAISE EXCEPTION 'FAIL [pension.current_value>=0]: CHECK haette ablehnen muessen';
  EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [pension.current_value>=0 lehnt -1 ab]'; END;

  -- transfer => group_id NOT NULL (Backstop zu fn_book_transfer/fn_book_recurring_transfer, finance:V022 validiert)
  DECLARE v_acc int; v_free_tx int; v_loan int; v_loan_tr int; v_loan_pr int; v_g1 uuid; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_chk_tr__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_acc;
    BEGIN
      INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
      VALUES (v_acc, 100, CURRENT_DATE, 'transfer');
      RAISE EXCEPTION 'FAIL [transfer ohne group_id]: CHECK haette ablehnen muessen';
    EXCEPTION WHEN check_violation THEN RAISE NOTICE 'PASS [transfer ohne group_id lehnt ab]'; END;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, group_id)
    VALUES (v_acc, 100, CURRENT_DATE, 'transfer', gen_random_uuid());
    IF NOT (SELECT convalidated FROM pg_constraint WHERE conname = 'finance_transactions_transfer_grouped') THEN
      RAISE EXCEPTION 'FAIL [transfer CHECK]: Constraint ist NOT VALID (V022 hat nicht validiert)'; END IF;
    RAISE NOTICE 'PASS [transfer mit group_id erlaubt, CHECK validiert]';

    -- V022-Backfill (Spiegel der beiden UPDATEs aus finance:V022 — V-Migrationen laufen nicht aus db_test heraus):
    -- Altzeilen (vor group_id) bekommen eine group_id; ein Kredit-Ereignis mit transfer-Bein bekommt fuer ALLE
    -- Beine eines (loan_id, Datum) EINE gemeinsame. Constraint dafuer kurz loesen (nur in dieser Transaktion).
    ALTER TABLE finance.transactions DROP CONSTRAINT finance_transactions_transfer_grouped;
    INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, status, loan_account_id)
    VALUES ('__test_chk_tr_loan__', 1000, CURRENT_DATE, 1.0, 'paused', v_acc) RETURNING id INTO v_loan;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category)
    VALUES (v_acc, 50, CURRENT_DATE, 'transfer') RETURNING id INTO v_free_tx;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
    VALUES (v_acc, -70, CURRENT_DATE - 3, 'transfer', v_loan) RETURNING id INTO v_loan_tr;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id)
    VALUES (v_acc, 70, CURRENT_DATE - 3, 'principal', v_loan) RETURNING id INTO v_loan_pr;
    UPDATE finance.transactions SET group_id = gen_random_uuid()
    WHERE category::text = 'transfer' AND group_id IS NULL AND loan_id IS NULL;
    WITH g AS MATERIALIZED (SELECT loan_id, transaction_date, gen_random_uuid() AS gid FROM finance.transactions
          WHERE category::text = 'transfer' AND group_id IS NULL AND loan_id IS NOT NULL
          GROUP BY loan_id, transaction_date)
    UPDATE finance.transactions t SET group_id = g.gid
    FROM g
    WHERE t.group_id IS NULL AND t.loan_id = g.loan_id AND t.transaction_date = g.transaction_date;
    SELECT group_id INTO v_g1 FROM finance.transactions WHERE id = v_free_tx;
    IF v_g1 IS NULL THEN RAISE EXCEPTION 'FAIL [V022 backfill]: Altzeile ohne group_id geblieben'; END IF;
    IF (SELECT group_id FROM finance.transactions WHERE id = v_loan_tr) IS NULL
       OR (SELECT group_id FROM finance.transactions WHERE id = v_loan_tr)
          IS DISTINCT FROM (SELECT group_id FROM finance.transactions WHERE id = v_loan_pr) THEN
      RAISE EXCEPTION 'FAIL [V022 backfill]: Kredit-Beine (transfer + principal) nicht in EINER Gruppe'; END IF;
    ALTER TABLE finance.transactions ADD CONSTRAINT finance_transactions_transfer_grouped
      CHECK (category::text <> 'transfer' OR group_id IS NOT NULL);
    RAISE NOTICE 'PASS [V022-Backfill: Altzeile bekommt group_id, Kredit-Beine eine gemeinsame, CHECK danach gueltig]';
  END;

  RAISE NOTICE 'PASS test_constraints_hardening [alle Backstops greifen]';
END $$;

ROLLBACK;
