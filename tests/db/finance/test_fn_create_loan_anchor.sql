-- tests/db/finance/test_fn_create_loan_anchor.sql
-- finance.fn_create_loan: passt first_payment_date nicht zum festen Monatstag, verankert die fn die Raten-Kette auf den
-- ersten Termin >= Eingabe mit diesem Tag (finance.fn_schedule_first_occurrence); effective meldet ihn (Karte "Erste Rate"
-- = gespeichert). valid_from der Kette bleibt (Auszahlung bzw. heute, Eroeffnungssaldo-Regel).
--   1) Anker: Rate am 1., Eingabe der 5. eines Monats -> erster Termin der 1. des Folgemonats; ohne Monatstag bleibt der Anker
--   2) Zins und Tilgung unveraendert: fn_loan_simulate liefert mit dem rohen und dem verankerten Anker dieselbe Restschuld,
--      dasselbe Tilgungsende und dieselbe Zinssumme
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v_giro     int;
  v_res      jsonb;
  v_first_in date := (date_trunc('month', CURRENT_DATE + 40) + interval '4 days')::date;   -- immer ein 5.
  v_expected date := (date_trunc('month', CURRENT_DATE + 40) + interval '1 month')::date;  -- der 1. danach
  v_rp       record;
  v_seg      jsonb;
  v_raw      record;
  v_new      record;
BEGIN
  SELECT (finance.fn_create_account(jsonb_build_object('name', '__t_lanc_giro', 'account_type', 'cash',
          'currency', 'EUR'))->>'account_id')::int INTO v_giro;

  -- (1) Anker
  v_res := finance.fn_create_loan(jsonb_build_object('name', '__t_lanc_kredit', 'lender', 'Testbank',
    'current_balance', 8000, 'interest_rate', 3, 'monthly_annuity', 250, 'schedule_day_of_month', '1',
    'first_payment_date', v_first_in::text, 'debit_account_id', v_giro));
  IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL [1] Setup: %', v_res; END IF;
  SELECT first_payment_date, valid_from INTO v_rp FROM finance.recurring_payments
   WHERE id = (v_res->>'recurring_payment_id')::int;
  IF v_rp.first_payment_date IS DISTINCT FROM v_expected
     OR v_res->'effective'->>'first_payment_date' IS DISTINCT FROM to_char(v_expected, 'YYYY-MM-DD') THEN
    RAISE EXCEPTION 'FAIL [1] erste Rate gespeichert %, effective %, erwartet %', v_rp.first_payment_date, v_res->'effective', v_expected; END IF;
  IF v_rp.valid_from > CURRENT_DATE THEN
    RAISE EXCEPTION 'FAIL [1] valid_from der Kette darf nicht dem Anker folgen (Auszahlung/heute), got %', v_rp.valid_from; END IF;

  v_res := finance.fn_create_loan(jsonb_build_object('name', '__t_lanc_kredit_ohne', 'lender', 'Testbank',
    'current_balance', 5000, 'interest_rate', 3, 'monthly_annuity', 200,
    'first_payment_date', v_first_in::text, 'debit_account_id', v_giro));
  IF (SELECT first_payment_date FROM finance.recurring_payments WHERE id = (v_res->>'recurring_payment_id')::int)
     IS DISTINCT FROM v_first_in THEN
    RAISE EXCEPTION 'FAIL [1b] ohne Monatstag bleibt der Anker: %', v_res; END IF;
  RAISE NOTICE 'PASS [1] erste Rate verankert, valid_from unveraendert, ohne Monatstag bleibt der Anker';

  -- (2) dieselben Raten mit rohem und verankertem Anker
  SELECT finance.fn_recurring_segments(r.id) INTO v_seg FROM finance.recurring_payments r
   WHERE r.name = (SELECT r2.name FROM finance.loans l JOIN finance.recurring_payments r2 ON r2.id = l.recurring_payment_id
                    WHERE l.name = '__t_lanc_kredit');
  SELECT * INTO v_new FROM finance.fn_loan_simulate(8000, 3, v_seg, NULL, CURRENT_DATE + 1200, CURRENT_DATE);
  SELECT * INTO v_raw FROM finance.fn_loan_simulate(8000, 3,
      jsonb_set(v_seg, '{0,anchor}', to_jsonb(v_first_in::text)), NULL, CURRENT_DATE + 1200, CURRENT_DATE);
  IF v_new.balance IS DISTINCT FROM v_raw.balance OR v_new.payoff_date IS DISTINCT FROM v_raw.payoff_date
     OR v_new.interest_total IS DISTINCT FROM v_raw.interest_total THEN
    RAISE EXCEPTION 'FAIL [2] Raten weichen ab: verankert %/%/%, roh %/%/%', v_new.balance, v_new.payoff_date, v_new.interest_total,
      v_raw.balance, v_raw.payoff_date, v_raw.interest_total; END IF;
  IF v_new.payoff_date IS NULL THEN
    RAISE EXCEPTION 'FAIL [2] Vergleich ohne Aussage: kein Tilgungsende im Fenster'; END IF;
  RAISE NOTICE 'PASS [2] Restschuld, Tilgungsende, Zinssumme gleich (% / % / %)', v_new.balance, v_new.payoff_date, v_new.interest_total;
END $$;
ROLLBACK;
