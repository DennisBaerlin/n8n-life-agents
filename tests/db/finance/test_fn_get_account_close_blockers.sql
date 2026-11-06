-- tests/db/finance/test_fn_get_account_close_blockers.sql
-- Testet fn_get_account_close_blockers (Audit F6): was das Schliessen eines Kontos verhindert. Vorher liess sich
--   ein Konto mit 3.000 EUR Guthaben schliessen -> das Geld verschwand aus dem Vermoegen; laufende Dauerauftraege
--   auf dem Konto feuerten danach taeglich einen Closed-Konto-Alarm.
BEGIN;

DO $$
DECLARE
  v_res    JSONB;
  v_b      JSONB;
  v_clean  INT;
  v_money  INT;
  v_rp_acc INT;
  v_settle INT;
  v_depot  INT;
  v_giro   INT;
  v_cnt0   INT;
  v_cnt1   INT;
  v_rp     INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__test_cb_clean__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_clean;
  SELECT (finance.fn_create_account('{"name":"__test_cb_money__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_money;
  SELECT (finance.fn_create_account('{"name":"__test_cb_rp__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_rp_acc;
  SELECT (finance.fn_create_account('{"name":"__test_cb_settle__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_settle;
  SELECT (finance.fn_create_account(jsonb_build_object('name','__test_cb_depot__','account_type','stocks_depot',
    'account_holder','T','currency','EUR','settlement_id',v_settle))->>'account_id')::int INTO v_depot;
  SELECT (finance.fn_create_account('{"name":"__test_cb_giro__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;

  -- TEST 1: leeres Konto ohne Bezuege -> nicht blockiert, read-only
  SELECT count(*) INTO v_cnt0 FROM finance.transactions;
  v_b := finance.fn_get_account_close_blockers(v_clean);
  SELECT count(*) INTO v_cnt1 FROM finance.transactions;
  IF (v_b->>'blocked')::boolean IS DISTINCT FROM false OR jsonb_array_length(v_b->'blockers') <> 0 OR v_cnt1 <> v_cnt0 THEN
    RAISE EXCEPTION 'FAIL blockers [sauber]: erwartet blocked=false, [] und kein Write, got %', v_b; END IF;
  RAISE NOTICE 'PASS blockers [leeres Konto -> nicht blockiert]';

  -- TEST 2: Saldo 3000 -> blockiert mit balance 3000
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_money, 3000, CURRENT_DATE, 'other');
  v_b := finance.fn_get_account_close_blockers(v_money);
  IF (v_b->>'blocked')::boolean IS DISTINCT FROM true
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e WHERE e->>'kind' = 'balance' AND (e->>'balance')::numeric = 3000) THEN
    RAISE EXCEPTION 'FAIL blockers [Saldo]: erwartet balance-Blocker 3000, got %', v_b; END IF;
  RAISE NOTICE 'PASS blockers [Saldo 3000 -> blockiert]';

  -- TEST 3: laufender (auch pausierter) Dauerauftrag als Quelle -> blockiert mit Namen
  SELECT (finance.fn_create_recurring_payment(jsonb_build_object('name','__test_cb_abo__','account_id',v_rp_acc,
    'direction','expense','amount',10,'schedule_unit','month','first_payment_date',(CURRENT_DATE + 3)::text))->>'recurring_payment_id')::int INTO v_rp;
  UPDATE finance.recurring_payments SET status = 'paused' WHERE id = v_rp;
  v_b := finance.fn_get_account_close_blockers(v_rp_acc);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e
                 WHERE e->>'kind' = 'recurring_payments' AND e->'names' ? '__test_cb_abo__') THEN
    RAISE EXCEPTION 'FAIL blockers [Dauerauftrag]: erwartet recurring_payments mit __test_cb_abo__, got %', v_b; END IF;
  RAISE NOTICE 'PASS blockers [pausierter/kuenftiger Dauerauftrag -> blockiert]';

  -- TEST 4: Depot mit Bestand -> blockiert (Depot-Saldo ist immer 0, der Bestand zaehlt)
  PERFORM finance.fn_book_stock_buy(jsonb_build_object('depot_id',v_depot,'settlement_id',v_settle,'isin','IE00B4L5Y983',
    'symbol','IUSQ','name','W','shares',2,'price_per_share',100,'order_fee',0,'transaction_date',CURRENT_DATE::text));
  v_b := finance.fn_get_account_close_blockers(v_depot);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e WHERE e->>'kind' = 'depot_holdings') THEN
    RAISE EXCEPTION 'FAIL blockers [Depotbestand]: erwartet depot_holdings, got %', v_b; END IF;
  -- Verrechnungskonto eines aktiven Depots (bestehender Grund) bleibt erhalten
  v_b := finance.fn_get_account_close_blockers(v_settle);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e WHERE e->>'kind' = 'settlement_for_depot') THEN
    RAISE EXCEPTION 'FAIL blockers [Verrechnungskonto]: erwartet settlement_for_depot, got %', v_b; END IF;
  RAISE NOTICE 'PASS blockers [Depotbestand + Verrechnungskonto -> blockiert]';

  -- TEST 5: Belastungskonto eines aktiven Kredits -> blockiert
  PERFORM finance.fn_create_loan(jsonb_build_object('name','__test_cb_kredit__','lender','B','borrower','T',
    'original_amount',1000,'current_balance',1000,'disbursement_date',CURRENT_DATE::text,'interest_rate',1,
    'monthly_annuity',100,'first_payment_date',(CURRENT_DATE + 10)::text,'debit_account_id',v_giro));
  v_b := finance.fn_get_account_close_blockers(v_giro);
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e
                 WHERE e->>'kind' = 'loans' AND e->'names' ? '__test_cb_kredit__') THEN
    RAISE EXCEPTION 'FAIL blockers [Kredit]: erwartet loans mit __test_cb_kredit__, got %', v_b; END IF;
  RAISE NOTICE 'PASS blockers [Belastungskonto eines aktiven Kredits -> blockiert]';

  -- TEST 6 (Review): beendeter Dauerauftrag mit noch OFFENER (ungebuchter) Rate im Erinnerungsfenster -> blockiert
  --   (sonst bietet die Erinnerung die Rate nach dem Schliessen an -> Closed-Konto-Trigger + Owner-Alarm)
  DECLARE v_end_acc INT; BEGIN
    SELECT (finance.fn_create_account('{"name":"__test_cb_ended__","account_type":"cash","account_holder":"T","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_end_acc;
    PERFORM finance.fn_add_recurring_payment(v_end_acc, -20, '__test_cb_ended_rp__', 1::smallint, 'month'::finance.schedule_unit,
      NULL, CURRENT_DATE - 20, CURRENT_DATE - 20, CURRENT_DATE - 2, NULL, NULL);
    v_b := finance.fn_get_account_close_blockers(v_end_acc);
    IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_b->'blockers') e
                   WHERE e->>'kind' = 'recurring_payments' AND e->'names' ? '__test_cb_ended_rp__') THEN
      RAISE EXCEPTION 'FAIL blockers [beendet, Rate offen]: erwartet recurring_payments, got %', v_b; END IF;
    RAISE NOTICE 'PASS blockers [beendeter Dauerauftrag mit offener Rate -> blockiert]';
  END;
END $$;

ROLLBACK;
