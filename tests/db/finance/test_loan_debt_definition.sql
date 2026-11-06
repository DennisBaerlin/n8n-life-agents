-- tests/db/finance/test_loan_debt_definition.sql
-- Audit Paket 2, Punkte 10 + 11.
--   10: EINE Schulden-Definition (finance.fn_loan_is_outstanding: Kredit active ODER paused). Ein pausierter Kredit
--       zaehlte im Vermoegen (networth, Kreditkonto-Saldo), fehlte aber in loan_summary (-> Advisor debt_total) und in
--       real_estate_overview.net_equity. Beispiel: Kredit A aktiv 100.000, Kredit B pausiert 50.000 auf derselben
--       Immobilie (Wert 400.000) -> total_debt -150.000, net_equity 250.000 (vorher -100.000 / 300.000).
--   11: fehlender Wechselkurs = Luecke als Flag (has_fx_gap), nicht still als 0 aus der Summe.
BEGIN;

DO $$
DECLARE
  v_res   JSONB;
  v_giro  INT;
  v_re    INT;
  v_la    INT;
  v_lb    INT;
  v_usd   INT;
  v_sum   RECORD;
BEGIN
  -- Ausgangslage isolieren: alle anderen Kredite/Immobilien des Test-Seeds aus der Summe nehmen
  UPDATE finance.loans SET status = 'paid_off' WHERE status IN ('active', 'paused');

  SELECT (finance.fn_create_account('{"name":"__test_ldd_giro__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int INTO v_giro;
  SELECT (finance.fn_create_real_estate(jsonb_build_object('name','__test_ldd_haus__','current_value',400000))->>'real_estate_id')::int INTO v_re;
  IF v_re IS NULL THEN RAISE EXCEPTION 'SETUP FAIL real_estate'; END IF;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__test_ldd_a__','lender','B','original_amount',100000,
    'current_balance',100000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',3,'monthly_annuity',500,
    'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_giro))->>'loan_id')::int INTO v_la;
  SELECT (finance.fn_create_loan(jsonb_build_object('name','__test_ldd_b__','lender','B','original_amount',50000,
    'current_balance',50000,'disbursement_date',(CURRENT_DATE - 30)::text,'interest_rate',3,'monthly_annuity',300,
    'first_payment_date',(CURRENT_DATE + 20)::text,'debit_account_id',v_giro))->>'loan_id')::int INTO v_lb;
  UPDATE finance.loans SET real_estate_id = v_re WHERE id IN (v_la, v_lb);
  UPDATE finance.loans SET status = 'paused' WHERE id = v_lb;

  -- 10a. loan_summary: Schulden inkl. pausiert, Zaehler getrennt
  SELECT * INTO v_sum FROM finance.loan_summary;
  IF v_sum.total_debt IS DISTINCT FROM -150000.00 OR v_sum.active_loan_count IS DISTINCT FROM 1
     OR v_sum.paused_loan_count IS DISTINCT FROM 1 OR v_sum.has_fx_gap IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL loan_summary: total_debt=% active=% paused=% fx_gap=%', v_sum.total_debt,
      v_sum.active_loan_count, v_sum.paused_loan_count, v_sum.has_fx_gap; END IF;
  RAISE NOTICE 'PASS loan_summary [pausierter Kredit zaehlt: total_debt -150000, 1 aktiv + 1 pausiert]';

  -- 10b. real_estate_overview: beide Kredite mindern das Eigenkapital
  IF (SELECT net_equity FROM finance.real_estate_overview WHERE id = v_re) IS DISTINCT FROM 250000.00
     OR (SELECT associated_debt FROM finance.real_estate_overview WHERE id = v_re) IS DISTINCT FROM -150000.00 THEN
    RAISE EXCEPTION 'FAIL real_estate_overview: net_equity=% debt=%',
      (SELECT net_equity FROM finance.real_estate_overview WHERE id = v_re),
      (SELECT associated_debt FROM finance.real_estate_overview WHERE id = v_re); END IF;
  RAISE NOTICE 'PASS real_estate_overview [net_equity 250000 inkl. pausiertem Kredit]';

  -- 10c. Nachlass-Register: pausierter Kredit enthalten, Restschuld positiv
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(finance.fn_liability_register()) e
                 WHERE e->>'name' = '__test_ldd_b__' AND (e->>'current_remaining_debt_eur')::numeric = 50000) THEN
    RAISE EXCEPTION 'FAIL liability_register [pausiert, positiv]: %', finance.fn_liability_register(); END IF;
  RAISE NOTICE 'PASS liability_register [pausierter Kredit mit Restschuld 50000]';

  -- 10d. Verkauf der Immobilie: Hinweis nennt auch den pausierten Kredit
  SELECT finance.fn_sell_real_estate(jsonb_build_object('real_estate_name','__test_ldd_haus__','sale_price',420000,
    'proceeds_account_id',v_giro,'sale_date',CURRENT_DATE::text)) INTO v_res;
  IF (v_res->>'linked_loan_count')::int IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL sell_real_estate [offene Kredite]: erwartet 2, got %', v_res; END IF;
  RAISE NOTICE 'PASS sell_real_estate [Hinweis nennt aktive + pausierte Kredite]';

  -- 11. Fremdwaehrung ohne Kurs: Konto in XTS (ISO-Testwaehrung, nie ein Kurs) -> has_fx_gap statt stiller 0
  PERFORM finance.fn_ensure_currency('XTS');
  SELECT (finance.fn_create_account('{"name":"__test_ldd_xts__","account_type":"cash","currency":"XTS"}'::jsonb)->>'account_id')::int INTO v_usd;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_usd, 1000, CURRENT_DATE, 'other');
  IF NOT EXISTS (SELECT 1 FROM finance.networth_by_asset_class WHERE bucket = 'cash' AND has_fx_gap) THEN
    RAISE EXCEPTION 'FAIL networth [fx_gap]: Fremdwaehrungs-Konto ohne Kurs nicht als Luecke markiert'; END IF;
  IF EXISTS (SELECT 1 FROM finance.networth_by_asset_class WHERE bucket = 'real_estate' AND has_fx_gap) THEN
    RAISE EXCEPTION 'FAIL networth [fx_gap]: Luecke faelschlich auf real_estate'; END IF;
  RAISE NOTICE 'PASS networth [Konto ohne Wechselkurs -> has_fx_gap]';
END $$;

ROLLBACK;
