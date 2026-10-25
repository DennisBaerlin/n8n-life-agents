-- tests/db/finance/test_fn_liquidity_snapshot.sql
-- finance.fn_liquidity_snapshot (WS-5 Runway-Bruecke, Provider-Seite): cash-only liquide Mittel +
-- Monats-Ausgaben/-Einnahmen fuer die career-Runway. PLAIN STABLE, KEIN DEFINER, KEIN Grant — wird vom
-- career-Renderer im fn_fetch_context-DEFINER-Kontext gelesen. RAISE-frei (laeuft im Render-Fetch:
-- ein RAISE braeche load_context ab), alles COALESCE'd. Liest NUR finance.*-Views (kein financial_planning).
-- Differenz-basierte Assertions (robust gegen Bestands-Fixtures der db_test-DB).
BEGIN;
DO $$
DECLARE
  s0 jsonb; s1 jsonb; s2 jsonb;
  v_cash0 numeric; v_cash1 numeric; v_exp0 numeric; v_exp1 numeric;
  v_cash int; v_fd int;
BEGIN
  -- ---------- TEST 0: RAISE-frei bei beliebigem Bestand, snapshot != NULL ----------
  s0 := finance.fn_liquidity_snapshot();
  IF s0 IS NULL THEN RAISE EXCEPTION 'FAIL [0]: snapshot NULL'; END IF;
  v_cash0 := COALESCE((s0->>'cash_eur')::numeric, 0);
  v_exp0  := COALESCE((s0->>'monthly_expenses_eur')::numeric, 0);
  IF v_exp0 < 0 THEN RAISE EXCEPTION 'FAIL [0]: monthly_expenses_eur negativ (muss ABS sein) %', v_exp0; END IF;
  RAISE NOTICE 'PASS [0] snapshot != NULL, RAISE-frei, monthly_expenses_eur >= 0';

  -- ---------- TEST 1: aktives Cash-Konto erhoeht cash_eur um den Saldo ----------
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__liq_cash__','cash','EUR','active') RETURNING id INTO v_cash;
  UPDATE finance.account_balances SET balance = 5000 WHERE account_id = v_cash;
  s1 := finance.fn_liquidity_snapshot();
  v_cash1 := (s1->>'cash_eur')::numeric;
  IF round(v_cash1 - v_cash0, 2) <> 5000 THEN RAISE EXCEPTION 'FAIL [1 cash delta]: % - % <> 5000', v_cash1, v_cash0; END IF;
  RAISE NOTICE 'PASS [1] Cash-Konto -> cash_eur +5000';

  -- ---------- TEST 2: Nicht-Cash-Konto (fixed_deposit) zaehlt NICHT in cash_eur ----------
  INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__liq_fd__','fixed_deposit','EUR','active','2030-12-31') RETURNING id INTO v_fd;
  UPDATE finance.account_balances SET balance = 99999 WHERE account_id = v_fd;
  IF (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric IS DISTINCT FROM v_cash1 THEN
    RAISE EXCEPTION 'FAIL [2 non-cash excluded]: cash_eur aenderte sich durch fixed_deposit'; END IF;
  RAISE NOTICE 'PASS [2] Nicht-Cash (fixed_deposit) zaehlt NICHT in cash_eur';

  -- ---------- TEST 3: Monats-Ausgabe erhoeht monthly_expenses_eur (ABS, positiv) ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__liq_exp__', v_cash, -2000, 'month', current_date, current_date);
  s2 := finance.fn_liquidity_snapshot();
  v_exp1 := (s2->>'monthly_expenses_eur')::numeric;
  IF round(v_exp1 - v_exp0, 2) <> 2000 THEN RAISE EXCEPTION 'FAIL [3 expense delta]: % - % <> 2000', v_exp1, v_exp0; END IF;
  IF v_exp1 < 0 THEN RAISE EXCEPTION 'FAIL [3 abs]: monthly_expenses_eur negativ %', v_exp1; END IF;
  RAISE NOTICE 'PASS [3] Monats-Ausgabe -> monthly_expenses_eur +2000 (ABS)';

  -- ---------- TEST 4: has_data Flag gesetzt (Cash/Ausgaben vorhanden) ----------
  IF (s2->>'has_data')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [4 has_data]: %', s2; END IF;
  RAISE NOTICE 'PASS [4] has_data=true bei Cash/Ausgaben';

  -- ---------- TEST 5 (WP-3c): Fremdwaehrungs-Cash-Konto OHNE FX-Kurs -> has_fx_gap=true, still NICHT in cash_eur ----------
  DECLARE v_krw int; s5 jsonb; v_cash_before numeric; BEGIN
    v_cash_before := (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric;
    INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__liq_krw__','cash','KRW','active') RETURNING id INTO v_krw;
    UPDATE finance.account_balances SET balance = 1450000 WHERE account_id = v_krw;   -- KRW-Guthaben, KEIN fx_rate
    s5 := finance.fn_liquidity_snapshot();
    IF (s5->>'has_fx_gap')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [5 has_fx_gap]: erwartet true (KRW-Konto ohne Kurs), got %', s5->>'has_fx_gap'; END IF;
    IF (s5->>'cash_eur')::numeric IS DISTINCT FROM v_cash_before THEN
      RAISE EXCEPTION 'FAIL [5 still not counted]: cash_eur aenderte sich ohne FX-Kurs (% -> %)', v_cash_before, s5->>'cash_eur'; END IF;
    RAISE NOTICE 'PASS [5] KRW-Cash ohne Kurs -> has_fx_gap=true, nicht in cash_eur (sichtbar statt still 0)';

    -- 5b: sobald ein KRW-Kurs vorliegt -> has_fx_gap=false + cash_eur steigt (1450000/1450 = 1000)
    INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of) VALUES ('EUR','KRW',1450,current_date) ON CONFLICT DO NOTHING;
    s5 := finance.fn_liquidity_snapshot();
    IF (s5->>'has_fx_gap')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [5b has_fx_gap]: erwartet false nach FX-Seed, got %', s5->>'has_fx_gap'; END IF;
    IF round((s5->>'cash_eur')::numeric - v_cash_before, 2) <> 1000 THEN
      RAISE EXCEPTION 'FAIL [5b cash delta]: erwartet +1000 EUR nach FX-Seed, got %', (s5->>'cash_eur')::numeric - v_cash_before; END IF;
    RAISE NOTICE 'PASS [5b] mit KRW-Kurs -> has_fx_gap=false, cash_eur +1000';
  END;

  -- ---------- Audit Paket 3: Pflicht-Basis + freies Cash ----------
  DECLARE
    v_depot int; v_rp int; v_loan int; v_kid int; v_pot int; v_goal int; v_chf int;
    sa jsonb; sb jsonb; v_e numeric; v_c numeric;
  BEGIN
    -- (6) ETF-Sparplan 600 ist KEINE Pflichtausgabe -> monthly_expenses_eur unveraendert
    v_e := (finance.fn_liquidity_snapshot()->>'monthly_expenses_eur')::numeric;
    INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
      VALUES ('__liq_depot__','stocks_depot','EUR','active', v_cash) RETURNING id INTO v_depot;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__liq_etf__', v_cash, -600, 'month', current_date, current_date) RETURNING id INTO v_rp;
    INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
      VALUES ('__liq_etf_plan__', v_depot, 'VWCE', 'World', v_rp);
    IF (finance.fn_liquidity_snapshot()->>'monthly_expenses_eur')::numeric IS DISTINCT FROM v_e THEN
      RAISE EXCEPTION 'FAIL [6]: Sparplan darf monthly_expenses_eur nicht erhoehen (% -> %)', v_e,
        finance.fn_liquidity_snapshot()->>'monthly_expenses_eur'; END IF;
    RAISE NOTICE 'PASS [6] Sparplan ist keine Pflichtausgabe';

    -- (7) Kreditrate 1000 (Zins 600 + Tilgung 400) IST Pflicht -> +1000
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__liq_loan__','loan','EUR','active') RETURNING id INTO v_loan;
    UPDATE finance.account_balances SET balance = -120000 WHERE account_id = v_loan;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__liq_loan_rate__', v_cash, -1000, 'month', current_date, current_date) RETURNING id INTO v_rp;
    INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate,
                               loan_account_id, debit_account_id, recurring_payment_id)
      VALUES ('__liq_loan__', 150000, current_date - 365, 6, v_loan, v_cash, v_rp);
    IF round((finance.fn_liquidity_snapshot()->>'monthly_expenses_eur')::numeric - v_e, 2) <> 1000 THEN
      RAISE EXCEPTION 'FAIL [7]: Kreditrate (Zins + Tilgung) muss als Pflicht +1000 zaehlen, got %',
        (finance.fn_liquidity_snapshot()->>'monthly_expenses_eur')::numeric - v_e; END IF;
    RAISE NOTICE 'PASS [7] Kreditrate inkl. Tilgung ist Pflichtausgabe';

    -- (8) Kinderkonto zaehlt nicht als freies Cash
    sa := finance.fn_liquidity_snapshot();
    INSERT INTO agent.persons (person_id, full_name, role) VALUES ('liq_kid', 'Kind', 'child');
    INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
      VALUES ('__liq_kid__','cash','EUR','active','liq_kid') RETURNING id INTO v_kid;
    UPDATE finance.account_balances SET balance = 3000 WHERE account_id = v_kid;
    IF (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric IS DISTINCT FROM (sa->>'cash_eur')::numeric THEN
      RAISE EXCEPTION 'FAIL [8]: Kinderkonto darf cash_eur nicht erhoehen'; END IF;
    RAISE NOTICE 'PASS [8] Kinderkonto ist kein Notgroschen';

    -- (9) Sparziel-Topf: 2000 Saldo, davon 1500 fuer ein aktives Ziel reserviert -> nur 500 frei, earmarked 1500
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__liq_pot__','cash','EUR','active') RETURNING id INTO v_pot;
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status) VALUES ('__liq_goal__', 5000, current_date + 365, 'active') RETURNING id INTO v_goal;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
      VALUES (v_pot, 1500, current_date, 'transfer', v_goal, gen_random_uuid()), (v_pot, 500, current_date, 'transfer', NULL, gen_random_uuid());
    sb := finance.fn_liquidity_snapshot();
    IF round((sb->>'cash_eur')::numeric - (sa->>'cash_eur')::numeric, 2) <> 500 THEN
      RAISE EXCEPTION 'FAIL [9 cash]: vom Topf (2000, reserviert 1500) darf nur 500 frei zaehlen, got %',
        (sb->>'cash_eur')::numeric - (sa->>'cash_eur')::numeric; END IF;
    IF round((sb->>'earmarked_eur')::numeric - COALESCE((sa->>'earmarked_eur')::numeric, 0), 2) <> 1500 THEN
      RAISE EXCEPTION 'FAIL [9 earmarked]: earmarked_eur erwartet +1500, got %', sb->>'earmarked_eur'; END IF;
    RAISE NOTICE 'PASS [9] Sparziel-Ruecklage ist kein freies Cash (earmarked 1500)';

    -- (10) Review #2: NEGATIVE Reserve-Markierung (Cash-Bein eines Ziel-Sparplan-Kaufs auf dem Giro) blaeht nichts auf
    --      (eigenes Giro: der Saldo-Trigger rechnet aus den Buchungen neu -> 1000 Gehalt - 200 Kauf = 800 frei)
    v_c := (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric;
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__liq_giro2__','cash','EUR','active') RETURNING id INTO v_rp;
    INSERT INTO finance.transactions (account_id, amount, transaction_date, category, savings_goal_id, group_id)
      VALUES (v_rp, 1000, current_date, 'transfer', NULL, gen_random_uuid()), (v_rp, -200, current_date, 'transfer', v_goal, gen_random_uuid());
    IF round((finance.fn_liquidity_snapshot()->>'cash_eur')::numeric - v_c, 2) <> 800 THEN
      RAISE EXCEPTION 'FAIL [10]: Giro 800 (reserviert -200) muss genau +800 frei zaehlen (negative Reserve nie addieren), got %',
        (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric - v_c; END IF;
    RAISE NOTICE 'PASS [10] negative Reserve-Tags erhoehen das freie Cash nicht';

    -- (11) 63-Punkt 11a: Fremdwaehrungs-Dauerauftrag ohne Kurs -> has_fx_gap (Pflicht-Basis unvollstaendig)
    PERFORM finance.fn_ensure_currency('CHF');
    DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF';
    INSERT INTO finance.accounts (name, account_type, currency, status, fixed_deposit_maturity_date) VALUES ('__liq_chf__','fixed_deposit','CHF','active','2030-12-31') RETURNING id INTO v_chf;
    IF (finance.fn_liquidity_snapshot()->>'has_fx_gap')::boolean IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [11 pre]: has_fx_gap vor dem CHF-Dauerauftrag erwartet false'; END IF;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
      VALUES ('__liq_chf_fee__', v_chf, -20, 'month', current_date, current_date);
    IF (finance.fn_liquidity_snapshot()->>'has_fx_gap')::boolean IS DISTINCT FROM true THEN
      RAISE EXCEPTION 'FAIL [11]: CHF-Dauerauftrag ohne Kurs muss has_fx_gap=true setzen'; END IF;
    RAISE NOTICE 'PASS [11] Fremdwaehrungs-Dauerauftrag ohne Kurs -> has_fx_gap';
  END;

  RAISE NOTICE 'PASS test_fn_liquidity_snapshot';
END $$;
ROLLBACK;
