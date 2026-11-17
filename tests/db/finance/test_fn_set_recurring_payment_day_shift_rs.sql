-- tests/db/finance/test_fn_set_recurring_payment_day_shift_rs.sql
-- Weitere Formen derselben Eigenschaft wie test_fn_set_recurring_payment_day_shift: eine Verschiebung des Buchungstags verliert und verdoppelt
-- keinen Termin -- am Ende einer befristeten Zahlung (R1), gegenueber schon gebuchten Monaten (R2), am Stichtag eines Splits (R3).
-- Gezaehlt ueber fn_upcoming_payments (Vorschau-Sicht) bzw. fn_recurring_due_open + Buchungen.
BEGIN;

-- R1: eine reine Verschiebung des Buchungstags aendert die Zahl der Termine im Geltungszeitraum nicht.
-- Befristete Zahlung mit fuenf Terminen; Tag frueher -> der erste faellt vor valid_from, Tag spaeter -> der letzte hinter valid_to.
DO $$
DECLARE v_acct INT; v_rp INT; v_res JSONB; v_n0 INT; v_n1 INT; r RECORD; v_bad TEXT := '';
BEGIN
  SELECT (finance.fn_create_account('{"name":"__r1_acct__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_acct;
  FOR r IN SELECT * FROM (VALUES (5),(25)) x(newdom) LOOP
    v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name','__r1_'||r.newdom||'__','account_id',v_acct,'direction','expense',
      'amount',100,'schedule_unit','month','schedule_day_of_month',15,'first_payment_date','2031-03-15','valid_to','2031-07-15'))->>'recurring_payment_id')::int;
    SELECT count(*) INTO v_n0 FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2031-12-31') WHERE recurring_payment_id = v_rp;
    v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',r.newdom));
    SELECT count(*) INTO v_n1 FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2031-12-31') WHERE recurring_payment_id = v_rp;
    IF v_n1 <> v_n0 THEN
      v_bad := v_bad || format(' [Tag 15 -> %s: ok=%s, Termine %s -> %s: %s]', r.newdom, v_res->>'ok', v_n0, v_n1,
        (SELECT string_agg(due_date::text, ',' ORDER BY due_date) FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2031-12-31') WHERE recurring_payment_id = v_rp));
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL R1 Tag verschoben, Zahl der Termine geaendert:%', v_bad; END IF;
END $$;

-- R2: nach einer Aenderung des Buchungstags darf kein schon bezahlter Monat wieder als offen erscheinen.
-- Monatlich am 10., seit drei Monaten, alle faelligen Termine gebucht; dann Tag -> 25 bzw. 3.
DO $$
DECLARE v_acct INT; v_rp INT; v_res JSONB; v_t DATE := current_date; r RECORD; v_bad TEXT := ''; v_open TEXT; v_booked TEXT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__r2_acct__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_acct;
  FOR r IN SELECT * FROM (VALUES (25),(3)) x(newdom) LOOP
    v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name','__r2_'||r.newdom||'__','account_id',v_acct,'direction','expense',
      'amount',100,'schedule_unit','month','schedule_day_of_month',10,
      'first_payment_date',(date_trunc('month', v_t) - interval '3 months')::date + 9))->>'recurring_payment_id')::int;
    PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',o.due_date))
      FROM finance.fn_recurring_due_open(v_t - 400, v_t) o WHERE o.recurring_payment_id = v_rp;
    SELECT string_agg(recurring_due_date::text, ',' ORDER BY recurring_due_date) INTO v_booked FROM finance.transactions WHERE recurring_payment_id = v_rp;
    v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'schedule_day_of_month',r.newdom));
    -- offen in einem Monat, in dem schon eine Buchung dieser Zahlung liegt = doppelt
    SELECT string_agg(o.due_date::text, ',' ORDER BY o.due_date) INTO v_open FROM finance.fn_recurring_due_open(v_t - 400, v_t + 31) o
      WHERE o.recurring_payment_id = v_rp
        AND EXISTS (SELECT 1 FROM finance.transactions t WHERE t.recurring_payment_id = v_rp
                      AND date_trunc('month', t.recurring_due_date) = date_trunc('month', o.due_date));
    IF v_open IS NOT NULL THEN
      v_bad := v_bad || format(' [Tag 10 -> %s: ok=%s, gebucht %s, in bezahlten Monaten wieder offen %s]', r.newdom, v_res->>'ok', v_booked, v_open);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL R2 bezahlte Monate erscheinen wieder offen:%', v_bad; END IF;
END $$;

-- R3: Betrag und Buchungstag in einem Aufruf aendern (Split) -- jeder Monat traegt weiter genau einen Termin.
-- Alt: am 15. Stichtag 10.06. + neuer Tag 5 -> Juni faellt aus. Stichtag 20.06. + neuer Tag 25 -> Juni doppelt.
DO $$
DECLARE v_acct INT; v_rp INT; v_new INT; v_res JSONB; r RECORD; v_bad TEXT := ''; v_m TEXT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__r3_acct__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_acct;
  FOR r IN SELECT * FROM (VALUES (DATE '2031-06-10', 5),(DATE '2031-06-20', 25)) x(eff, newdom) LOOP
    v_rp := (finance.fn_create_recurring_payment(jsonb_build_object('name','__r3_'||r.newdom||'__','account_id',v_acct,'direction','expense',
      'amount',100,'schedule_unit','month','schedule_day_of_month',15,'first_payment_date','2031-01-15'))->>'recurring_payment_id')::int;
    v_res := finance.fn_set_recurring_payment(jsonb_build_object('recurring_payment_id',v_rp,'amount',120,'valid_from',r.eff,'schedule_day_of_month',r.newdom));
    v_new := (v_res->>'recurring_payment_id')::int;
    SELECT string_agg(to_char(m, 'YYYY-MM') || ': ' || c || 'x', ', ') INTO v_m FROM (
      SELECT m, (SELECT count(*) FROM finance.fn_upcoming_payments(DATE '2031-04-01', DATE '2031-08-31') u
                  WHERE u.recurring_payment_id IN (v_rp, v_new) AND date_trunc('month', u.due_date) = m) AS c
      FROM generate_series(DATE '2031-04-01', DATE '2031-08-01', interval '1 month') m) q WHERE c <> 1;
    IF v_m IS NOT NULL THEN
      v_bad := v_bad || format(' [Stichtag %s, Tag 15 -> %s, ok=%s: %s]', r.eff, r.newdom, v_res->>'ok', v_m);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL R3 Monat ohne bzw. mit zwei Terminen:%', v_bad; END IF;
END $$;

ROLLBACK;
