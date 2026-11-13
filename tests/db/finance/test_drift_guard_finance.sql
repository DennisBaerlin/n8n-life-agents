-- tests/db/finance/test_drift_guard_finance.sql
-- Absicherung der DB-Seite von Drift-Funden, deren Fehler nicht in der fn liegt. Die fn kann hier bereits, was die Tool-Description verneint oder umstaendlich beschreibt;
-- der Fix gehoert in Description bzw. Tool-Graph und darf diese Faehigkeit nicht verlieren.
BEGIN;

-- (S2.6) Description von tool_book_recurring_occurrence: "ok:false if ... internal transfer (those book the planned
-- amount only)". Die DB bucht einen angepassten Betrag auch bei einer Dauerueberweisung, auf beiden Beinen.
DO $$
DECLARE r jsonb; v_a int; v_b int; v_rp int;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__dg_s26_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__dg_s26_tg__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_recurring_transfer(jsonb_build_object('name','__dg_s26_dauer__','from_account_id',v_a,
         'to_account_id',v_b,'amount','200','schedule_unit','month','first_payment_date',(CURRENT_DATE - 2)::text));
  v_rp := (r->>'recurring_payment_id')::int;
  r := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,
         'due_date',(CURRENT_DATE - 2)::text,'amount','250'));
  IF NOT (r->>'ok')::boolean
     OR (SELECT amount FROM finance.transactions WHERE id = (r->>'debit_tx_id')::int) IS DISTINCT FROM -250
     OR (SELECT amount FROM finance.transactions WHERE id = (r->>'credit_tx_id')::int) IS DISTINCT FROM 250 THEN
    RAISE EXCEPTION 'FAIL [S2.6] Transfer-Override 250 nicht auf beiden Beinen gebucht, got %', r;
  END IF;
  RAISE NOTICE 'PASS [S2.6] Dauerueberweisung nimmt den angepassten Betrag (-250/+250)';
END $$;

-- (S3.15) Sparplan-Description nennt symbol "Required". Die DB nimmt fuer ein Aktien-Depot die ISIN allein und lehnt
-- ein Aktien-Depot ohne ISIN korrigierbar ab.
DO $$
DECLARE r jsonb; v_c int;
BEGIN
  v_c := (finance.fn_create_account('{"name":"__dg_s315_ver__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  PERFORM finance.fn_create_account(jsonb_build_object('name','__dg_s315_depot__','account_type','stocks_depot','settlement_id',v_c));
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__dg_s315_plan__','depot_name','__dg_s315_depot__',
         'isin','IE00B4L5Y983','symbol','','security_name','Beispiel Welt ETF','amount',100,'schedule_unit','month',
         'first_payment_date',(CURRENT_DATE + 5)::text));
  IF NOT (r->>'ok')::boolean THEN RAISE EXCEPTION 'FAIL [S3.15] Sparplan nur mit ISIN abgelehnt: %', r; END IF;
  r := finance.fn_create_savings_plan(jsonb_build_object('name','__dg_s315_plan2__','depot_name','__dg_s315_depot__',
         'symbol','BSPL','security_name','Beispiel','amount',100,'schedule_unit','month',
         'first_payment_date',(CURRENT_DATE + 5)::text));
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [S3.15] Aktien-Depot-Sparplan ohne ISIN angenommen: %', r; END IF;
  RAISE NOTICE 'PASS [S3.15] ISIN genuegt, ohne ISIN korrigierbare Ablehnung';
END $$;

-- (S4.2) Sondertilgung "5.000 EUR": payment_amount = principal_amount = 5000 ergibt Zins 0, Tilgung 5000. Die DB
-- rechnet das richtig, die Description macht nur die Feldbelegung nicht klar.
DO $$
DECLARE r jsonb; v_giro int; v_loan int;
BEGIN
  v_giro := (finance.fn_create_account('{"name":"__dg_s42_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_loan(jsonb_build_object('name','__dg_s42_kredit__','lender','Beispielbank','original_amount',80000,
         'current_balance',60000,'disbursement_date',(CURRENT_DATE - 400)::text,'interest_rate',3,
         'monthly_annuity',700,'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_giro));
  v_loan := (r->>'loan_id')::int;
  r := finance.fn_get_loan_payment_split(jsonb_build_object('loan_id',v_loan,'payment_amount',5000,'principal_amount',5000));
  IF NOT (r->>'ok')::boolean OR (r->>'interest_portion')::numeric IS DISTINCT FROM 0
     OR (r->>'principal_amount')::numeric IS DISTINCT FROM 5000 THEN
    RAISE EXCEPTION 'FAIL [S4.2] Sondertilgung payment=principal=5000: erwartet Zins 0 / Tilgung 5000, got %', r; END IF;
  RAISE NOTICE 'PASS [S4.2] Sondertilgung ohne Zinsanteil';
END $$;

-- (S3.8) Wieder-Oeffnen eines geschlossenen Sparziels: der Resolver findet es nur mit p_active_only = FALSE (das Tool
-- ruft heute TRUE und kommt nie bei fn_set_savings_goal an; das Re-Open selbst sichert test_fn_set_savings_goal).
DO $$
DECLARE v_acct int; r jsonb; v_t int; v_f int;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__dg_s38_pot__','cash','EUR','active');
  v_acct := (finance.fn_create_account('{"name":"__dg_s38_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int;
  r := finance.fn_create_savings_goal(jsonb_build_object('name','__dg_s38_ziel__','target_amount',3000,
         'target_date',(CURRENT_DATE + 365)::text,'monthly_savings_rate',100,
         'reserve_account_id',(SELECT max(id) FROM finance.accounts WHERE name='__dg_s38_pot__'),
         'account_id',v_acct,'first_payment_date',(CURRENT_DATE + 3)::text));
  -- Buchung auf der Rate erzwingt Soft-Close (status cancelled), sonst wuerde das Ziel hart geloescht
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, description)
  VALUES (v_acct, -100, CURRENT_DATE - 1, 'other', (r->>'recurring_payment_id')::int, 'Beispiel');
  r := finance.fn_close_savings_goal('{"savings_goal_name":"__dg_s38_ziel__","outcome":"cancelled","force":true}'::jsonb);
  IF r->>'action' IS DISTINCT FROM 'closed' THEN RAISE EXCEPTION 'SETUP [S3.8] Soft-Close erwartet, got %', r; END IF;
  SELECT hit_count INTO v_t FROM finance.fn_resolve_savings_goal('__dg_s38_ziel__', TRUE);
  SELECT hit_count INTO v_f FROM finance.fn_resolve_savings_goal('__dg_s38_ziel__', FALSE);
  IF v_t <> 0 OR v_f <> 1 THEN
    RAISE EXCEPTION 'FAIL [S3.8] Resolver: active_only TRUE % Treffer (erwartet 0), FALSE % (erwartet 1)', v_t, v_f; END IF;
  RAISE NOTICE 'PASS [S3.8] geschlossenes Ziel nur mit p_active_only=FALSE aufloesbar';
END $$;

ROLLBACK;
