-- tests/db/finance/test_recalc2_loan_special.sql
-- Zweitrechnung Runde 2, Kredit-Sonderfaelle: laufender Kredit (ohne Ursprungswerte), Restschuld zum Zinsbindungsende,
-- Tilgungsende, anfaengliche Tilgung, pausierter Kredit in der Summe, Dispo (ueberzogenes Konto) in der Vermoegens-Sicht.
-- Erwartungen mit eigener PowerShell-Decimal-Schleife hergeleitet (Monatszins = Rest x Satz / 12 auf Cent, Tilgung =
-- Rate - Zins), Gegenprobe geschlossene Formel. Werte erfunden.
-- Quelle Annuitaet/Restschuld: https://de.wikipedia.org/wiki/Annuit%C3%A4tendarlehen ; anfaengliche Tilgung =
--   (Jahresrate / Darlehensbetrag x 100) - Sollzins (https://de.wikipedia.org/wiki/Tilgung_(Kredit)).
--   (1) Laufender Kredit: Rest heute 100.000, 3 % p. a., Rate 800 monatlich ab in 5 Tagen, Zinsbindung bis zur 24. Rate:
--       Zins jetzt 100.000 x 3 % / 12 = 250,00, Tilgung 550,00;
--       Rest nach 24 Raten 86.413,43 (geschlossene Formel 86.413,45; Cent-Rundung je Monat);
--       getilgt mit der 151. Rate (= erste Rate + 150 Monate), Zinsen bis dahin 20.051,74.
--       Ohne Kreditbetrag -> anfaengliche Tilgung unbekannt (NULL).
--   (2) Mit Kreditbetrag 120.000 und erster Rate 800: 9.600 / 120.000 x 100 - 3 = 5,00 %.
--   (3) Zweiter Kredit pausiert, Rest 4.000: Summe Restschuld -104.000, Raten/Zins/Tilgung nur vom laufenden
--       (800 / 250 / 550), 1 laufend + 1 pausiert.
--   (4) Dispo: Giro -350,25 neben Tagesgeld 0 -> Vermoegens-Sicht zaehlt das Konto mit -350,25 (Verbindlichkeit),
--       freies Geld (Runway-Basis) sinkt um 350,25 statt ignoriert zu werden.
BEGIN;

UPDATE finance.recurring_payments SET status = 'paused';
UPDATE finance.loans SET status = 'paid_off' WHERE status IN ('active', 'paused');
UPDATE finance.accounts SET status = 'closed' WHERE status = 'active';

DO $$
DECLARE
  v_giro int; v_la int; v_lb int; v_rp int; v_l int; v_l2 int; r record; s record; v_first date := current_date + 5; v_cash numeric;
BEGIN
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2ls_giro__', 'cash', 'EUR', 'active') RETURNING id INTO v_giro;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2ls_la__', 'loan', 'EUR', 'active') RETURNING id INTO v_la;
  INSERT INTO finance.accounts (name, account_type, currency, status) VALUES ('__r2ls_lb__', 'loan', 'EUR', 'active') RETURNING id INTO v_lb;
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2ls_rate__', v_giro, -800, 'month', v_first, current_date) RETURNING id INTO v_rp;
  INSERT INTO finance.loans (name, interest_rate, interest_rate_fixed_until, status, loan_account_id, debit_account_id, recurring_payment_id)
    VALUES ('__r2ls_lauf__', 3.0, (v_first + interval '23 months')::date, 'active', v_la, v_giro, v_rp) RETURNING id INTO v_l;
  INSERT INTO finance.loans (name, interest_rate, status, loan_account_id) VALUES ('__r2ls_ruht__', 0, 'paused', v_lb) RETURNING id INTO v_l2;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, loan_id) VALUES
    (v_la, -100000, current_date - 1, 'disbursement', v_l), (v_lb, -4000, current_date - 1, 'disbursement', v_l2);

  SELECT * INTO r FROM finance.loan_overview WHERE id = v_l;
  IF r.monthly_interest_current IS DISTINCT FROM 250.00 OR r.monthly_principal_current IS DISTINCT FROM 550.00
     OR r.initial_principal_rate IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [1a] Zins/Tilgung jetzt: %', row_to_json(r); END IF;
  IF r.balance_at_fixed_until_projected IS DISTINCT FROM 86413.43 THEN
    RAISE EXCEPTION 'FAIL [1b] Rest zum Zinsbindungsende: erwartet 86413.43, got %', r.balance_at_fixed_until_projected; END IF;
  IF r.payoff_date_projected IS DISTINCT FROM (v_first + interval '150 months')::date OR r.interest_remaining_projected IS DISTINCT FROM 20051.74 THEN
    RAISE EXCEPTION 'FAIL [1c] Tilgungsende: erwartet % / 20051.74, got % / %', (v_first + interval '150 months')::date,
      r.payoff_date_projected, r.interest_remaining_projected; END IF;
  RAISE NOTICE 'PASS [1] Laufender Kredit: 250/550, Rest 86.413,43 zur Bindung, 151. Rate tilgt, Zinsen 20.051,74';

  UPDATE finance.loans SET original_amount = 120000, disbursement_date = current_date - 400 WHERE id = v_l;
  SELECT * INTO r FROM finance.loan_overview WHERE id = v_l;
  IF r.initial_principal_rate IS DISTINCT FROM 5.00 THEN RAISE EXCEPTION 'FAIL [2] anfaengliche Tilgung: %', r.initial_principal_rate; END IF;
  RAISE NOTICE 'PASS [2] anfaengliche Tilgung 5,00 %%';

  SELECT * INTO s FROM finance.loan_summary;
  IF s.total_debt IS DISTINCT FROM -104000.00 OR s.total_monthly_payment IS DISTINCT FROM 800.00
     OR s.total_monthly_interest IS DISTINCT FROM 250.00 OR s.total_monthly_principal IS DISTINCT FROM 550.00
     OR s.active_loan_count IS DISTINCT FROM 1::bigint OR s.paused_loan_count IS DISTINCT FROM 1::bigint THEN
    RAISE EXCEPTION 'FAIL [3] Kredit-Summe: %', row_to_json(s); END IF;
  RAISE NOTICE 'PASS [3] Summe: pausierter Rest zaehlt, Raten nur vom laufenden';

  v_cash := (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric;
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category) VALUES (v_giro, -350.25, current_date - 1, 'other');
  IF (SELECT value_eur FROM finance.networth_items WHERE item_kind = 'account' AND item_id = v_giro) IS DISTINCT FROM -350.25 THEN
    RAISE EXCEPTION 'FAIL [4a] Dispo in der Vermoegens-Sicht'; END IF;
  IF (finance.fn_liquidity_snapshot()->>'cash_eur')::numeric IS DISTINCT FROM v_cash - 350.25 THEN
    RAISE EXCEPTION 'FAIL [4b] Dispo mindert das freie Geld: vorher %, nachher %', v_cash, finance.fn_liquidity_snapshot()->>'cash_eur'; END IF;
  RAISE NOTICE 'PASS [4] Dispo -350,25 als Verbindlichkeit und im freien Geld';

  -- (5) Raten-Aufteilung (fn_get_loan_payment_split): Quartalsrate traegt drei Monatszinsen; Ueberzahlung nennt den
  --     Abloesebetrag. Kredit 2 (ruht) bekommt dafuer eine Quartals-Kette: Rest 4.000, 4,8 % -> Zins 4.000 x 4,8 % / 12 x 3
  --     = 48,00, Rate 1.500 -> Tilgung 1.452,00; Rate 4.100 -> Tilgung 4.052 > 4.000 -> abgelehnt, Abloese 4.048,00.
  INSERT INTO finance.recurring_payments (name, account_id, amount, schedule_interval, schedule_unit, first_payment_date, valid_from)
    VALUES ('__r2ls_quartal__', v_giro, -1500, 3, 'month', current_date + 20, current_date) RETURNING id INTO v_rp;
  UPDATE finance.loans SET interest_rate = 4.8, status = 'active', recurring_payment_id = v_rp WHERE id = v_l2;
  IF (finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 1500))->>'interest_portion')::numeric IS DISTINCT FROM 48.00
     OR (finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 1500))->>'principal_amount')::numeric IS DISTINCT FROM 1452.00 THEN
    RAISE EXCEPTION 'FAIL [5a] Quartalsrate: %', finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 1500)); END IF;
  IF (finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 4100))->>'ok')::boolean IS DISTINCT FROM false
     OR (finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 4100))->>'payoff_amount')::numeric IS DISTINCT FROM 4048.00 THEN
    RAISE EXCEPTION 'FAIL [5b] Ueberzahlung: %', finance.fn_get_loan_payment_split(jsonb_build_object('loan_id', v_l2, 'payment_amount', 4100)); END IF;
  RAISE NOTICE 'PASS [5] Quartalsrate 48 Zins / 1.452 Tilgung, Ueberzahlung -> Abloese 4.048';
END $$;

ROLLBACK;
