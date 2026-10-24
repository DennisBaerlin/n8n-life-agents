-- tests/db/finance/test_recurring_cashflow_classified.sql
-- Audit Paket 3 P2: EINE Klassifikations-Quelle fuer den Cashflow (finance.recurring_cashflow_classified)
-- + die Summen-Spalten von monthly_cashflow_summary. Konsum, Tilgung, Sparen getrennt:
--   income (>0) -> loan (Kredit-rp: Zins = Konsum, Rest = Tilgung) -> saving (Sparplan/Sparziel/Vorsorge,
--   negativ) bzw. saving_internal (Spar-rp auf einem Konto, das selbst eine laufende Spar-Ueberweisung
--   empfaengt -> 0, sonst doppelt gespart) -> transfer (own<->own, 0) -> consumption.
-- Kumulativ aufgebaut (eine leere Test-DB, absolute Erwartungen je Schritt).
BEGIN;

DO $$
DECLARE
  v_giro INT; v_tg INT; v_depot INT; v_loan_acct INT; v_loan2_acct INT; v_other INT;
  v_rp INT; v_rp_goal INT;
  s record;
  c record;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_giro__','cash','EUR','active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_tg__','cash','EUR','active') RETURNING id INTO v_tg;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_other__','cash','EUR','active') RETURNING id INTO v_other;
  INSERT INTO finance.accounts (name, account_type, currency, status, settlement_account_id)
    VALUES ('__cfc_depot__','stocks_depot','EUR','active', v_giro) RETURNING id INTO v_depot;

  -- ---------- Schritt 1 (Auftrags-Beispiel): Einnahmen 3000, Konsum 2500, ETF-Sparplan 600 ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_salary__', v_giro, 3000, 1, 'month', current_date, current_date, 'active');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_rent__', v_giro, -2500, 1, 'month', current_date, current_date, 'active');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_etf__', v_giro, -600, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__cfc_etf_plan__', v_depot, 'VWCE', 'World ETF', v_rp);

  SELECT cashflow_class, consumption_eur, saving_eur, principal_eur INTO c
    FROM finance.recurring_cashflow_classified WHERE name = '__cfc_etf__';
  IF c.cashflow_class IS DISTINCT FROM 'saving' OR c.saving_eur IS DISTINCT FROM -600 OR c.consumption_eur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [1 etf]: ETF-Sparplan muss saving -600 sein, got %', row_to_json(c); END IF;

  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_income IS DISTINCT FROM 3000 OR s.monthly_consumption IS DISTINCT FROM -2500
     OR s.monthly_saving IS DISTINCT FROM -600 OR s.monthly_principal IS DISTINCT FROM 0
     OR s.monthly_obligations IS DISTINCT FROM -2500 OR s.monthly_free IS DISTINCT FROM 500
     OR s.monthly_account_change IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL [1 summary]: erwartet 3000/-2500/-600/0/-2500/frei 500/Konto -100, got %', row_to_json(s); END IF;
  IF s.income_count <> 1 OR s.consumption_count <> 1 OR s.saving_count <> 1 OR s.loan_count <> 0 THEN
    RAISE EXCEPTION 'FAIL [1 counts]: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [1: 3000/2500/ETF 600 -> frei 500, Konto -100, ETF = Sparen]';

  -- ---------- Schritt 2: Kredit 1000/Monat, Restschuld 120.000 bei 6 % -> Zins 600 (Konsum), Tilgung 400 ----------
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_loan__','loan','EUR','active') RETURNING id INTO v_loan_acct;
  UPDATE finance.account_balances SET balance = -120000 WHERE account_id = v_loan_acct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_loan_rate__', v_giro, -1000, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, principal_rate, monthly_annuity,
                             loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__cfc_loan__', 150000, current_date - 365, 6, 2, 1000, v_loan_acct, v_giro, v_rp);

  SELECT cashflow_class, consumption_eur, saving_eur, principal_eur INTO c
    FROM finance.recurring_cashflow_classified WHERE name = '__cfc_loan_rate__';
  IF c.cashflow_class IS DISTINCT FROM 'loan' OR c.consumption_eur IS DISTINCT FROM -600
     OR c.principal_eur IS DISTINCT FROM -400 OR c.saving_eur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [2 loan row]: erwartet loan Zins -600 / Tilgung -400, got %', row_to_json(c); END IF;
  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_consumption IS DISTINCT FROM -3100 OR s.monthly_principal IS DISTINCT FROM -400
     OR s.monthly_obligations IS DISTINCT FROM -3500 OR s.monthly_free IS DISTINCT FROM -500
     OR s.monthly_account_change IS DISTINCT FROM -1100 OR s.loan_count <> 1 THEN
    RAISE EXCEPTION 'FAIL [2 summary]: erwartet Konsum -3100 / Tilgung -400 / Pflicht -3500 / frei -500 / Konto -1100, got %', row_to_json(s); END IF;
  -- Formel-Helfer = dieselbe Zahl wie die Zins/Tilgungs-Vorschau (ein Formel-Ort)
  IF finance.fn_loan_monthly_interest(120000, 6) IS DISTINCT FROM 600.00 THEN
    RAISE EXCEPTION 'FAIL [2 helper]: fn_loan_monthly_interest(120000,6) erwartet 600, got %', finance.fn_loan_monthly_interest(120000, 6); END IF;
  RAISE NOTICE 'PASS [2: Kreditrate 1000 -> Zins 600 Konsum, Tilgung 400 Pflicht]';

  -- ---------- Schritt 3: Sparziel MIT Topf (Giro -> Tagesgeld 300) = Sparen, steht in der Overview ----------
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_goal_rate__', v_giro, v_tg, -300, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp_goal;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
    VALUES ('__cfc_goal__', 3600, current_date + 365, 'active', v_rp_goal);
  IF NOT EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE name = '__cfc_goal_rate__' AND cashflow_class = 'saving') THEN
    RAISE EXCEPTION 'FAIL [3]: Sparziel-Topf-Rate fehlt als saving in monthly_cashflow_overview'; END IF;
  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_saving IS DISTINCT FROM -900 OR s.monthly_account_change IS DISTINCT FROM -1400 THEN
    RAISE EXCEPTION 'FAIL [3 summary]: erwartet Sparen -900 / Konto -1400, got %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [3: Sparziel-Ueberweisung zaehlt als Sparen]';

  -- ---------- Schritt 4 (Review #3): Sparplan kauft AUS dem Topf -> saving_internal (0, nicht doppelt) ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_etf_from_pot__', v_tg, -300, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__cfc_etf_pot_plan__', v_depot, 'EIMI', 'EM ETF', v_rp);
  SELECT cashflow_class, saving_eur INTO c FROM finance.recurring_cashflow_classified WHERE name = '__cfc_etf_from_pot__';
  IF c.cashflow_class IS DISTINCT FROM 'saving_internal' OR c.saving_eur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [4]: Sparplan aus dem Topf muss saving_internal / 0 sein, got %', row_to_json(c); END IF;
  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_saving IS DISTINCT FROM -900 THEN
    RAISE EXCEPTION 'FAIL [4 summary]: Sparen bleibt -900 (kein Doppel-Sparen), got %', s.monthly_saving; END IF;
  RAISE NOTICE 'PASS [4: Sparplan aus dem Sparziel-Topf zaehlt nicht doppelt]';

  -- ---------- Schritt 5: Alt-Sparziel OHNE Topf (nackte Abbuchung 100) = Sparen, nicht Konsum ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_old_goal_rate__', v_giro, -100, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
    VALUES ('__cfc_old_goal__', 1200, current_date + 365, 'active', v_rp);
  -- ---------- Schritt 6: Vorsorge-Beitrag 200 = Sparen; Vorsorge-AUSZAHLUNG +500 = Einnahme ----------
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_pension_contrib__', v_giro, -200, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.pension (name, pension_type, recurring_payment_id) VALUES ('__cfc_pension__', 'private', v_rp);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_pension_payout__', v_giro, 500, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.pension (name, pension_type, recurring_payment_id) VALUES ('__cfc_pension2__', 'private', v_rp);
  IF (SELECT cashflow_class FROM finance.recurring_cashflow_classified WHERE name = '__cfc_pension_payout__') IS DISTINCT FROM 'income' THEN
    RAISE EXCEPTION 'FAIL [6]: Vorsorge-Auszahlung (+) muss income sein (Reihenfolge income vor saving)'; END IF;
  -- ---------- Schritt 7: own<->own-Transfer 150 (kein Ziel) -> transfer, NICHT in der Overview ----------
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_own__', v_giro, v_other, -150, 1, 'month', current_date, current_date, 'active');
  IF (SELECT cashflow_class FROM finance.recurring_cashflow_classified WHERE name = '__cfc_own__') IS DISTINCT FROM 'transfer' THEN
    RAISE EXCEPTION 'FAIL [7]: own<->own muss transfer sein'; END IF;
  IF EXISTS (SELECT 1 FROM finance.monthly_cashflow_overview WHERE name = '__cfc_own__') THEN
    RAISE EXCEPTION 'FAIL [7]: own<->own-Transfer darf nicht in monthly_cashflow_overview stehen'; END IF;

  SELECT * INTO s FROM finance.monthly_cashflow_summary;
  IF s.monthly_income IS DISTINCT FROM 3500 OR s.monthly_saving IS DISTINCT FROM -1200
     OR s.monthly_consumption IS DISTINCT FROM -3100 OR s.monthly_account_change IS DISTINCT FROM -1200 THEN
    RAISE EXCEPTION 'FAIL [5-7 summary]: erwartet Einnahmen 3500 / Sparen -1200 / Konsum -3100 / Konto -1200, got %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [5-7: Alt-Ziel + Vorsorge = Sparen, Auszahlung = Einnahme, own<->own neutral]';

  -- ---------- Schritt 8: Zins > Rate (Restschuld 300.000 @ 6 % = 1500 > Rate 1000) -> Konsum = Rate, Tilgung 0 ----------
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_loan2__','loan','EUR','active') RETURNING id INTO v_loan2_acct;
  UPDATE finance.account_balances SET balance = -300000 WHERE account_id = v_loan2_acct;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_loan2_rate__', v_giro, -1000, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, principal_rate, monthly_annuity,
                             loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__cfc_loan2__', 300000, current_date - 30, 6, 0, 1000, v_loan2_acct, v_giro, v_rp);
  SELECT consumption_eur, principal_eur INTO c FROM finance.recurring_cashflow_classified WHERE name = '__cfc_loan2_rate__';
  IF c.consumption_eur IS DISTINCT FROM -1000 OR c.principal_eur IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [8]: Zins > Rate -> Konsum -1000 / Tilgung 0 (nie positiv), got %', row_to_json(c); END IF;
  RAISE NOTICE 'PASS [8: Zins ueber der Rate -> ganze Rate Konsum, Tilgung 0]';

  -- has_fx_gap bisher false (alles EUR)
  IF (SELECT has_fx_gap FROM finance.monthly_cashflow_summary) IS DISTINCT FROM false THEN
    RAISE EXCEPTION 'FAIL [fx0]: has_fx_gap muss false sein, solange alles EUR ist'; END IF;
END $$;

-- ---------- Schritt 9 (Review #10): fehlender Wechselkurs wird sichtbar, nie still 0 ----------
DO $$
DECLARE
  v_chf INT; v_giro INT; v_loan_chf INT; v_rp INT;
  c record;
BEGIN
  PERFORM finance.fn_ensure_currency('CHF');
  DELETE FROM finance.fx_rates WHERE quote_currency = 'CHF';
  SELECT id INTO v_giro FROM finance.accounts WHERE name = '__cfc_giro__';

  -- (9a) CHF-Abo ohne Kurs -> Zeile fx_gap, Summary has_fx_gap
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_chf__','cash','CHF','active') RETURNING id INTO v_chf;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_chf_sub__', v_chf, -50, 1, 'month', current_date, current_date, 'active');
  IF (SELECT fx_gap FROM finance.recurring_cashflow_classified WHERE name = '__cfc_chf_sub__') IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [9a]: CHF-rp ohne Kurs muss fx_gap=true tragen'; END IF;
  IF (SELECT has_fx_gap FROM finance.monthly_cashflow_summary) IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [9a]: Summary has_fx_gap muss true sein'; END IF;

  -- (9b) EUR-Rate eines CHF-Kredits ohne Kurs -> Zins unbekannt: ganze Rate Konsum + fx_gap (nie verschwinden)
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_loan_chf__','loan','CHF','active') RETURNING id INTO v_loan_chf;
  UPDATE finance.account_balances SET balance = -50000 WHERE account_id = v_loan_chf;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_loan_chf_rate__', v_giro, -400, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, principal_rate, monthly_annuity,
                             loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__cfc_loan_chf__', 50000, current_date - 30, 3, 2, 400, v_loan_chf, v_giro, v_rp);
  SELECT consumption_eur, principal_eur, fx_gap INTO c FROM finance.recurring_cashflow_classified WHERE name = '__cfc_loan_chf_rate__';
  IF c.consumption_eur IS DISTINCT FROM -400 OR c.principal_eur IS DISTINCT FROM 0 OR c.fx_gap IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL [9b]: Kreditwaehrung ohne Kurs -> Konsum -400 / Tilgung 0 / fx_gap, got %', row_to_json(c); END IF;
  RAISE NOTICE 'PASS [9: fehlender Wechselkurs -> fx_gap sichtbar, Kreditrate faellt nicht still heraus]';
END $$;

-- ---------- Code-Review: TEILWEISE Gegenfinanzierung -> nur der gedeckte Anteil faellt heraus ----------
DO $$
DECLARE
  v_giro INT; v_pot2 INT; v_depot INT; v_rp INT; v_before numeric; v_after numeric;
  c record;
BEGIN
  SELECT id INTO v_giro FROM finance.accounts WHERE name = '__cfc_giro__';
  SELECT id INTO v_depot FROM finance.accounts WHERE name = '__cfc_depot__';
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_pot2__','cash','EUR','active') RETURNING id INTO v_pot2;
  SELECT monthly_saving INTO v_before FROM finance.monthly_cashflow_summary;
  -- Ziel-Rate 50 in den Topf, ETF-Sparplan 500 vom Topf -> 50 gegenfinanziert, 450 echtes Sparen
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_pot2_goal_rate__', v_giro, v_pot2, -50, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
    VALUES ('__cfc_pot2_goal__', 600, current_date + 365, 'active', v_rp);
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_pot2_etf__', v_pot2, -500, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__cfc_pot2_plan__', v_depot, 'POT2', 'Pot2 ETF', v_rp);
  SELECT cashflow_class, saving_eur INTO c FROM finance.recurring_cashflow_classified WHERE name = '__cfc_pot2_etf__';
  IF c.cashflow_class IS DISTINCT FROM 'saving' OR c.saving_eur IS DISTINCT FROM -450.00 THEN
    RAISE EXCEPTION 'FAIL [partial]: Sparplan 500 bei 50 Gegenfinanzierung -> saving -450, got %', row_to_json(c); END IF;
  SELECT monthly_saving INTO v_after FROM finance.monthly_cashflow_summary;
  IF v_after - v_before IS DISTINCT FROM -500.00 THEN
    RAISE EXCEPTION 'FAIL [partial summary]: Sparen gesamt +500 erwartet (50 + 450), got %', v_after - v_before; END IF;
  RAISE NOTICE 'PASS [partial: nur der gegenfinanzierte Anteil faellt aus dem Sparen]';
END $$;

-- ---------- Plan-Review #4: in die Zukunft geaenderter Sparplan -> die alte, noch laufende Zeile bleibt Sparen ----------
DO $$
DECLARE
  v_giro INT; v_depot INT; v_old INT; v_new INT;
BEGIN
  SELECT id INTO v_giro FROM finance.accounts WHERE name = '__cfc_giro__';
  SELECT id INTO v_depot FROM finance.accounts WHERE name = '__cfc_depot__';
  -- alte Rate laeuft bis in 30 Tagen, die neue (Nachfolger, predecessor_id) gilt erst danach; der Plan zeigt auf den Kopf
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, valid_to, status)
    VALUES ('__cfc_split_old__', v_giro, -200, 1, 'month', current_date - 60, current_date - 60, current_date + 30, 'active') RETURNING id INTO v_old;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status, predecessor_id)
    VALUES ('__cfc_split_new__', v_giro, -300, 1, 'month', current_date - 60, current_date + 30, 'active', v_old) RETURNING id INTO v_new;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__cfc_split_plan__', v_depot, 'SPLT', 'Split ETF', v_new);
  IF (SELECT cashflow_class FROM finance.recurring_cashflow_classified WHERE name = '__cfc_split_old__') IS DISTINCT FROM 'saving' THEN
    RAISE EXCEPTION 'FAIL [lineage]: alte Zeile eines in die Zukunft geaenderten Sparplans muss saving sein, got %',
      (SELECT cashflow_class FROM finance.recurring_cashflow_classified WHERE name = '__cfc_split_old__'); END IF;
  RAISE NOTICE 'PASS [lineage: alte Zeile bis zum Stichtag weiter Sparen (Besitzer am Kopf der Kette)]';

  -- dasselbe fuer einen Kredit: die alte, noch laufende Raten-Zeile bleibt 'loan' (Zins/Tilgung), nicht Konsum
  DECLARE v_lacct int; v_lold int; v_lnew int; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_split_loan__','loan','EUR','active') RETURNING id INTO v_lacct;
    UPDATE finance.account_balances SET balance = -60000 WHERE account_id = v_lacct;   -- 60.000 @ 6 % = Zins 300
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, valid_to, status)
      VALUES ('__cfc_split_loan_old__', v_giro, -500, 1, 'month', current_date - 60, current_date - 60, current_date + 30, 'active') RETURNING id INTO v_lold;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status, predecessor_id)
      VALUES ('__cfc_split_loan_new__', v_giro, -600, 1, 'month', current_date - 60, current_date + 30, 'active', v_lold) RETURNING id INTO v_lnew;
    INSERT INTO finance.loans (name, original_amount, disbursement_date, interest_rate, principal_rate, monthly_annuity,
                               loan_account_id, debit_account_id, recurring_payment_id)
      VALUES ('__cfc_split_loan__', 70000, current_date - 365, 6, 4, 600, v_lacct, v_giro, v_lnew);
    IF (SELECT row(cashflow_class, consumption_eur, principal_eur)::text FROM finance.recurring_cashflow_classified
        WHERE name = '__cfc_split_loan_old__') IS DISTINCT FROM '(loan,-300.00,-200.00)' THEN
      RAISE EXCEPTION 'FAIL [lineage loan]: alte Kreditrate muss loan mit Zins -300 / Tilgung -200 sein, got %',
        (SELECT row(cashflow_class, consumption_eur, principal_eur)::text FROM finance.recurring_cashflow_classified
         WHERE name = '__cfc_split_loan_old__'); END IF;
    RAISE NOTICE 'PASS [lineage loan: alte Kreditrate bleibt Zins + Tilgung]';
  END;

  -- Code-Review: Sparziel, dessen alte Rate (ohne Topf) noch laeuft, waehrend der Kopf (mit Topf) erst spaeter gilt
  -- -> noch NICHT messbar (sonst Pace gegen eine unverfolgte Abbuchung)
  DECLARE v_gold int; v_gnew int; v_pot int; BEGIN
    INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__cfc_split_pot__','cash','EUR','active') RETURNING id INTO v_pot;
    INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, valid_to, status)
      VALUES ('__cfc_split_goal_old__', v_giro, -100, 1, 'month', current_date - 60, current_date - 60, current_date + 30, 'active') RETURNING id INTO v_gold;
    INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status, predecessor_id)
      VALUES ('__cfc_split_goal_new__', v_giro, v_pot, -100, 1, 'month', current_date - 60, current_date + 30, 'active', v_gold) RETURNING id INTO v_gnew;
    INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id)
      VALUES ('__cfc_split_goal__', 2400, current_date + 700, 'active', v_gnew);
    IF (SELECT progress_measurable FROM finance.savings_goal_progress WHERE name = '__cfc_split_goal__') IS DISTINCT FROM false THEN
      RAISE EXCEPTION 'FAIL [lineage goal]: laufende alte Rate ohne Topf -> progress_measurable muss false sein'; END IF;
    RAISE NOTICE 'PASS [lineage goal: messbar erst, wenn keine laufende Rate ohne Topf mehr existiert]';
  END;
END $$;

-- ---------- Eltern-Scope (Review #14): dieselbe Klassifikation, Kind-Konten raus ----------
DO $$
DECLARE
  v_kid INT; v_giro INT; v_rp INT; v_depot INT;
  s record;
  v_before numeric; v_after numeric;
BEGIN
  INSERT INTO agent.persons (person_id, full_name, role) VALUES ('cfc_kid', 'Kind', 'child');
  SELECT id INTO v_giro FROM finance.accounts WHERE name = '__cfc_giro__';
  SELECT id INTO v_depot FROM finance.accounts WHERE name = '__cfc_depot__';
  INSERT INTO finance.accounts (name, account_type, currency, status, owner_person_id)
    VALUES ('__cfc_kid__','cash','EUR','active','cfc_kid') RETURNING id INTO v_kid;
  SELECT monthly_saving INTO v_before FROM finance.monthly_cashflow_summary;

  -- Eltern->Kind-Sparziel-Ueberweisung 100 + Kind-Sparplan 100 vom Kindkonto: in der FAMILIE nur einmal Sparen
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_kid_goal_rate__', v_giro, v_kid, -100, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_goals (name, target_amount, target_date, status, recurring_payment_id, beneficiary_person_id)
    VALUES ('__cfc_kid_goal__', 1200, current_date + 365, 'active', v_rp, 'cfc_kid');
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from, status)
    VALUES ('__cfc_kid_plan_rate__', v_kid, -100, 1, 'month', current_date, current_date, 'active') RETURNING id INTO v_rp;
  INSERT INTO finance.savings_plans (name, depot_id, symbol, security_name, recurring_payment_id)
    VALUES ('__cfc_kid_plan__', v_depot, 'KIDS', 'Kids ETF', v_rp);
  SELECT monthly_saving INTO v_after FROM finance.monthly_cashflow_summary;
  IF v_after - v_before IS DISTINCT FROM -100 THEN
    RAISE EXCEPTION 'FAIL [P1]: Familie: Eltern->Kind-Ziel + Kind-Sparplan = einmal -100 Sparen, got %', v_after - v_before; END IF;

  -- Eltern-Scope: dieselben Spalten; Ziel-Ueberweisung ans Kind = Sparen, Kind-eigene Zeilen raus
  SELECT * INTO s FROM finance.parent_cashflow_summary;
  IF s.monthly_saving IS NULL OR s.monthly_obligations IS NULL OR s.monthly_free IS NULL OR s.monthly_account_change IS NULL THEN
    RAISE EXCEPTION 'FAIL [P2]: parent_cashflow_summary braucht dieselben Spalten, got %', row_to_json(s); END IF;
  IF EXISTS (SELECT 1 FROM finance.parent_cashflow_overview WHERE name = '__cfc_kid_plan_rate__') THEN
    RAISE EXCEPTION 'FAIL [P2]: Kind-Sparplan gehoert nicht in den Eltern-Scope'; END IF;
  IF (SELECT cashflow_class FROM finance.parent_cashflow_overview WHERE name = '__cfc_kid_goal_rate__') IS DISTINCT FROM 'saving' THEN
    RAISE EXCEPTION 'FAIL [P2]: Eltern->Kind-Sparziel-Rate ist im Eltern-Scope Sparen'; END IF;
  RAISE NOTICE 'PASS [Eltern-Scope: gleiche Klassifikation, Kind-Zeilen raus, kein Doppel-Sparen in der Familie]';
END $$;

ROLLBACK;
