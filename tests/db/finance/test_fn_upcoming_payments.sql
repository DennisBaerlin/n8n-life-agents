-- tests/db/finance/test_fn_upcoming_payments.sql
-- finance.fn_upcoming_payments(p_from, p_until) — offene Dauerauftrags-Vorkommen eines Zeitraums mit dem Betrag, den die
-- Buchung nehmen wuerde (eine Quelle fuer Kontovorschau fn_account_outlook und den Mini-App-Bildschirm „Zahlungen“).
--   1) offen ja, gebucht (Faelligkeit) / uebersprungen nein; Fenstergrenzen inklusiv; p_from in der Vergangenheit bleibt
--   2) Uebertrag: account_id = Quelle, target_account_id = Ziel, amount signiert wie die Zeile, planned_amount roh
--   3) Kreditrate: letzte, kleinere Rate = Abloesebetrag (fn_recurring_occurrence_amount), planned_amount = geplante Rate
--   4) pausiert / ausserhalb der Gueltigkeit -> keine Zeile
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  t DATE := CURRENT_DATE;
  v_a INT; v_b INT; v_rp_abo INT; v_rp_tr INT; v_rp_p INT; v_loan JSONB; v_rp_loan INT; v_n INT; v_amt NUMERIC; v_plan NUMERIC;
BEGIN
  v_a := (finance.fn_create_account('{"name":"__t_up_a__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_b := (finance.fn_create_account('{"name":"__t_up_b__","account_type":"cash","currency":"EUR"}'::jsonb)->>'account_id')::int;
  v_rp_abo := finance.fn_add_recurring_payment(v_a, -20, 'Up Abo', 7::smallint, 'day'::finance.schedule_unit, NULL, t - 7, t - 7, NULL, NULL, NULL);
  INSERT INTO finance.recurring_payments (name, account_id, target_account_id, amount, schedule_interval, schedule_unit,
                                          first_payment_date, valid_from)
  VALUES ('Up Uebertrag', v_a, v_b, -75, 30, 'day', t + 5, t + 5) RETURNING id INTO v_rp_tr;
  v_rp_p := finance.fn_add_recurring_payment(v_a, -999, 'Up pausiert', 1::smallint, 'day'::finance.schedule_unit, NULL, t, t, NULL,
                                              'paused'::finance.payment_status, NULL);
  -- Abo: t-7 gebucht (Faelligkeit, am Folgetag abgebucht), t uebersprungen -> offen bleiben t+7, t+14 (und t-? keins)
  INSERT INTO finance.transactions (account_id, amount, transaction_date, category, recurring_payment_id, recurring_due_date)
  VALUES (v_a, -20, t - 6, 'other', v_rp_abo, t - 7);
  INSERT INTO finance.recurring_payment_skips (recurring_payment_id, due_date) VALUES (v_rp_abo, t);

  -- ===== 1) offen / gebucht / uebersprungen / Grenzen / Vergangenheit =====
  SELECT count(*) INTO v_n FROM finance.fn_upcoming_payments(t - 7, t + 14) u WHERE u.recurring_payment_id = v_rp_abo;
  IF v_n <> 2 OR NOT EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(t - 7, t + 14) u
                             WHERE u.recurring_payment_id = v_rp_abo AND u.due_date = t + 14) THEN
    RAISE EXCEPTION 'FAIL [1a] Abo: erwartet offen t+7 und t+14 (t-7 gebucht, t uebersprungen), got %', v_n; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(t + 8, t + 13) u WHERE u.recurring_payment_id = v_rp_abo) THEN
    RAISE EXCEPTION 'FAIL [1b] Fenster ohne Termin liefert eine Zeile'; END IF;
  DELETE FROM finance.recurring_payment_skips WHERE recurring_payment_id = v_rp_abo;
  IF NOT EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(t - 3, t) u WHERE u.recurring_payment_id = v_rp_abo AND u.due_date = t) THEN
    RAISE EXCEPTION 'FAIL [1c] p_from in der Vergangenheit / Grenze inklusiv'; END IF;
  RAISE NOTICE 'PASS [1] offen ja, gebucht/uebersprungen nein, Grenzen inklusiv';

  -- ===== 2) Uebertrag =====
  SELECT u.amount, u.planned_amount INTO v_amt, v_plan FROM finance.fn_upcoming_payments(t, t + 30) u
   WHERE u.recurring_payment_id = v_rp_tr AND u.account_id = v_a AND u.target_account_id = v_b AND u.due_date = t + 5;
  IF v_amt IS DISTINCT FROM -75 OR v_plan IS DISTINCT FROM -75 THEN
    RAISE EXCEPTION 'FAIL [2] Uebertrag Quelle/Ziel/Betrag: % / %', v_amt, v_plan; END IF;
  RAISE NOTICE 'PASS [2] Uebertrag Quelle -> Ziel, Betrag signiert';

  -- ===== 3) Kreditrate: Rest 300 < Rate 500 -> Abloesebetrag =====
  v_loan := finance.fn_create_loan(jsonb_build_object('name', '__t_up_kredit__', 'lender', 'B', 'borrower', 'T',
    'original_amount', 5000, 'current_balance', 300, 'disbursement_date', (t - 60)::text, 'interest_rate', 3,
    'monthly_annuity', 500, 'first_payment_date', (t + 3)::text, 'debit_account_id', v_a));
  SELECT recurring_payment_id INTO v_rp_loan FROM finance.loans WHERE id = (v_loan->>'loan_id')::int;
  SELECT u.amount, u.planned_amount INTO v_amt, v_plan FROM finance.fn_upcoming_payments(t, t + 10) u
   WHERE u.recurring_payment_id = v_rp_loan AND u.due_date = t + 3;
  IF v_plan IS DISTINCT FROM -500 OR v_amt IS DISTINCT FROM finance.fn_recurring_occurrence_amount(v_rp_loan, t + 3)
     OR NOT (v_amt > -500 AND v_amt < -300) THEN
    RAISE EXCEPTION 'FAIL [3] Kredit-Schlussrate: amount % (erwartet Abloese zwischen -300 und -500), planned %', v_amt, v_plan; END IF;
  RAISE NOTICE 'PASS [3] Kredit-Schlussrate = Abloesebetrag %, geplant -500', v_amt;

  -- ===== 4) pausiert / ausserhalb der Gueltigkeit =====
  IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(t, t + 30) u WHERE u.recurring_payment_id = v_rp_p) THEN
    RAISE EXCEPTION 'FAIL [4a] pausierte Zahlung geliefert'; END IF;
  UPDATE finance.recurring_payments SET valid_to = t + 6 WHERE id = v_rp_abo;
  IF EXISTS (SELECT 1 FROM finance.fn_upcoming_payments(t + 1, t + 30) u WHERE u.recurring_payment_id = v_rp_abo) THEN
    RAISE EXCEPTION 'FAIL [4b] Vorkommen nach valid_to geliefert'; END IF;
  RAISE NOTICE 'PASS [4] pausiert / beendet -> keine Zeile';
END $$;
ROLLBACK;
