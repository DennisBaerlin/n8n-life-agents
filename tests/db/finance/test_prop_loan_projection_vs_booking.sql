-- tests/db/finance/test_prop_loan_projection_vs_booking.sql
-- Eigenschafts-Test: die Kredit-Vorschau (fn_loan_projected_balance, fn_loan_projected_payoff: Restschuld zu einem
-- Datum, Tilgungsende, Zinsen bis dahin) gegen das echte Buchen jeder Rate ueber fn_book_recurring_occurrence, bis der
-- Kredit abbezahlt ist. Vorschau und Buchung laufen ueber verschiedene Wege (fn_loan_simulate gegen
-- fn_get_loan_payment_split + Saldo-Trigger); beide muessen auf den Cent dasselbe ergeben.
--   K1 Restschuld zum Zwischendatum = Saldo des Kreditkontos nach den bis dahin gebuchten Raten
--   K2 Tilgungsende = Termin der Rate, die den Kredit abloest; Zinsen bis dahin = Summe der gebuchten Zinsanteile
--   K3 nach einer Raten-Aenderung (fn_set_loan, Stichtag = naechster offener Termin) gilt K1/K2 fuer die neue Vorschau,
--      und die Termine der Raten-Kette sind dieselben wie vorher
--   K4 nach einer Sondertilgung (reine Tilgung, kein Termin erledigt) gilt K1/K2 fuer die neue Vorschau
BEGIN;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_b JSONB; v_giro INT; v_loan INT; v_rp INT; v_la INT; r RECORD; o RECORD;
  v_mid DATE; v_pmid NUMERIC; v_amid NUMERIC; v_pd DATE; v_pi NUMERIC; v_int NUMERIC; v_last DATE; v_n INT; v_i INT := 0;
  v_changed BOOLEAN; v_dates0 DATE[]; v_dates1 DATE[];
BEGIN
  SELECT (finance.fn_create_account('{"name":"__prop_lpb_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_giro;

  FOR r IN SELECT * FROM (VALUES
      (10000.00, 4.00, 500.00,  15, 0),   (10000.00, 0.00, 500.00,  1, 0),  (7300.00, 7.25, 333.33, -1, 0),
      (2500.00,  3.50, 410.00,  28, 0),   (12000.00, 2.10, 1000.00, -2, 0), (9999.99, 5.55, 777.77, 14, 0),
      (10000.00, 4.00, 500.00,  15, 3),   (7300.00,  7.25, 333.33,  -1, 5), (12000.00, 2.10, 1000.00, 1, 1),
      (10000.00, 4.00, 500.00,  15, -2),  (12000.00, 2.10, 1000.00, -2, -4)
    ) x(bal, rate, ann, dom, change_after) LOOP
    v_i := v_i + 1;
    v_res := finance.fn_create_loan(jsonb_build_object('name','__prop_lpb_loan'||v_i||'__','lender','Testbank','current_balance',r.bal,
      'interest_rate',r.rate,'monthly_annuity',r.ann,'schedule_day_of_month',r.dom,'first_payment_date',(v_t + 3),'debit_account_id',v_giro));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL K setup %: %', r, v_res; END IF;
    v_loan := (v_res->>'loan_id')::int; v_rp := (v_res->>'recurring_payment_id')::int; v_la := (v_res->>'loan_account_id')::int;
    v_mid := (v_t + interval '7 months')::date;
    v_changed := (r.change_after = 0);
    IF v_changed THEN
      v_pmid := finance.fn_loan_projected_balance(v_loan, v_mid, v_t);
      SELECT payoff_date, interest_total INTO v_pd, v_pi FROM finance.fn_loan_projected_payoff(v_loan, v_t);
    END IF;
    v_int := 0; v_n := 0; v_amid := NULL; v_last := NULL;
    LOOP
      SELECT d.due_date, d.recurring_payment_id INTO o FROM finance.fn_recurring_due_open(v_t, (v_t + interval '6 years')::date) d
        WHERE d.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp)) ORDER BY d.due_date LIMIT 1;
      EXIT WHEN o.due_date IS NULL;
      -- K3: nach change_after gebuchten Raten die Rate um 50 erhoehen (Stichtag-Default = naechster offener Termin)
      IF NOT v_changed AND v_n = r.change_after THEN
        SELECT array_agg(d.due_date ORDER BY d.due_date) INTO v_dates0 FROM finance.fn_recurring_due_open(v_t, (v_t + interval '2 years')::date) d
          WHERE d.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
        v_res := finance.fn_set_loan(jsonb_build_object('loan_id',v_loan,'monthly_annuity',r.ann + 50));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL K3 %: fn_set_loan %', r, v_res; END IF;
        SELECT array_agg(d.due_date ORDER BY d.due_date) INTO v_dates1 FROM finance.fn_recurring_due_open(v_t, (v_t + interval '2 years')::date) d
          WHERE d.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(v_rp));
        IF v_dates1 IS DISTINCT FROM v_dates0 THEN
          RAISE EXCEPTION 'FAIL K3 %: Termine vor der Raten-Aenderung % danach %', r, v_dates0, v_dates1; END IF;
        IF (v_res->>'effective_from')::date IS DISTINCT FROM o.due_date THEN
          RAISE EXCEPTION 'FAIL K3 %: neue Rate gilt ab %, naechster offener Termin ist %', r, v_res->>'effective_from', o.due_date; END IF;
        v_changed := true;
        v_pmid := finance.fn_loan_projected_balance(v_loan, v_mid, v_t);
        SELECT payoff_date, interest_total INTO v_pd, v_pi FROM finance.fn_loan_projected_payoff(v_loan, v_t);
        v_int := 0;   -- interest_total der neuen Vorschau zaehlt ab jetzt
        CONTINUE;     -- naechsten offenen Termin neu lesen (er liegt jetzt auf dem neuen Glied)
      END IF;
      -- K4: nach -change_after gebuchten Raten eine Sondertilgung (kein Raten-Betrag, zwei Tage nach der letzten Rate)
      IF NOT v_changed AND r.change_after < 0 AND v_n = -r.change_after THEN
        v_res := finance.fn_book_loan_payment(jsonb_build_object('loan_id',v_loan,'loan_account_id',v_la,'debit_account_id',v_giro,
                   'payment_amount',1234.56,'payment_date',v_last + 2));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true OR (v_res->>'principal_amount')::numeric IS DISTINCT FROM 1234.56
           OR (v_res->>'matched_due_date') IS NOT NULL THEN
          RAISE EXCEPTION 'FAIL K4 %: Sondertilgung nicht als reine Tilgung gebucht: %', r, v_res; END IF;
        v_changed := true;
        v_pmid := finance.fn_loan_projected_balance(v_loan, v_mid, v_t);
        SELECT payoff_date, interest_total INTO v_pd, v_pi FROM finance.fn_loan_projected_payoff(v_loan, v_t);
        v_int := 0;
        CONTINUE;
      END IF;
      IF v_amid IS NULL AND o.due_date > v_mid THEN
        v_amid := -(SELECT balance FROM finance.account_balances WHERE account_id = v_la);
      END IF;
      v_b := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date));
      IF (v_b->>'ok')::boolean IS DISTINCT FROM true AND (v_b->>'payoff_amount') IS NOT NULL THEN
        v_b := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date,
                 'amount',(v_b->>'payoff_amount')::numeric));
      END IF;
      IF (v_b->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL K %: Rate % nicht buchbar: %', r, o.due_date, v_b; END IF;
      v_n := v_n + 1; v_int := v_int + (v_b->>'interest_portion')::numeric; v_last := o.due_date;
      EXIT WHEN (v_b->>'loan_status') = 'paid_off';
      IF v_n > 400 THEN RAISE EXCEPTION 'FAIL K %: nach 400 Raten nicht abbezahlt', r; END IF;
    END LOOP;
    IF v_amid IS NULL THEN v_amid := 0; END IF;   -- schon vor dem Zwischendatum abbezahlt
    IF (SELECT status FROM finance.loans WHERE id = v_loan) <> 'paid_off' THEN
      RAISE EXCEPTION 'FAIL K %: Kredit nach allen Raten nicht abbezahlt', r; END IF;
    IF v_pmid IS DISTINCT FROM v_amid THEN
      RAISE EXCEPTION 'FAIL K1 %: Vorschau Restschuld zum % = %, gebucht %', r, v_mid, v_pmid, v_amid; END IF;
    IF v_pd IS DISTINCT FROM v_last OR v_pi IS DISTINCT FROM v_int THEN
      RAISE EXCEPTION 'FAIL K2 %: Vorschau Tilgungsende % Zinsen %, gebucht % / % (% Raten)', r, v_pd, v_pi, v_last, v_int, v_n; END IF;
  END LOOP;
  RAISE NOTICE 'PASS prop loan projection vs booking [% Kredite bis zur Abloesung durchgebucht, K1-K4]', v_i;
END $$;

ROLLBACK;
