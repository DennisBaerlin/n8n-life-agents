-- tests/db/finance/test_prop_first_due_multi_month.sql
-- Eigenschaft: Quartals-/Jahres-Zahlung mit festem Tag: der erste Termin ist der naechste solche Tag ab dem genannten
-- Datum (wie beim Monatsrhythmus), nie ein ganzes Intervall spaeter; danach laeuft der Rhythmus von dort.
-- Kombinationen: Rhythmus (1/3/6/12 Monate, Jahr) x Tag (1, 15, -1) x genanntes Datum (vor/auf/nach dem Tag im Monat).
-- Erwartung steht schriftlich hergeleitet im Test, nicht aus der fn abgeschrieben.
BEGIN;
DO $$
DECLARE
  v_acct INT; v_res JSONB; r RECORD; v_first DATE; v_second DATE; v_bad TEXT := ''; v_rp INT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__fdm_acct__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_acct;
  FOR r IN SELECT * FROM (VALUES
      -- Einheit, Intervall, Tag, genanntes Datum, erwarteter erster Termin, erwarteter zweiter Termin
      ('month', 1,  1, '2031-02-10', '2031-03-01', '2031-04-01'),
      ('month', 3,  1, '2031-02-10', '2031-03-01', '2031-06-01'),
      ('month', 12, 1, '2031-02-10', '2031-03-01', '2032-03-01'),
      ('year',  1,  1, '2031-02-10', '2031-03-01', '2032-03-01'),
      ('month', 3,  1, '2031-02-01', '2031-02-01', '2031-05-01'),
      ('month', 3, 15, '2031-02-10', '2031-02-15', '2031-05-15'),
      ('month', 3, 15, '2031-02-20', '2031-03-15', '2031-06-15'),
      ('month', 12,15, '2031-02-20', '2031-03-15', '2032-03-15'),
      ('month', 3, -1, '2031-04-10', '2031-04-30', '2031-07-31'),
      ('month', 6, -1, '2031-04-30', '2031-04-30', '2031-10-31')
    ) x(u, intv, dom, named, e1, e2) LOOP
    v_res := finance.fn_create_recurring_payment(jsonb_build_object('name','__fdm_'||r.u||r.intv||'_'||r.dom||'_'||r.named||'__',
      'account_id',v_acct,'direction','expense','amount',100,'schedule_unit',r.u,'schedule_interval',r.intv,
      'schedule_day_of_month',r.dom,'first_payment_date',r.named));
    IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'SETUP FAIL %: %', r, v_res; END IF;
    v_rp := (v_res->>'recurring_payment_id')::int;
    SELECT d INTO v_first  FROM (SELECT due_date AS d FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2034-12-31')
                                 WHERE recurring_payment_id = v_rp ORDER BY due_date LIMIT 1) a;
    SELECT d INTO v_second FROM (SELECT due_date AS d FROM finance.fn_upcoming_payments(DATE '2031-01-01', DATE '2034-12-31')
                                 WHERE recurring_payment_id = v_rp ORDER BY due_date OFFSET 1 LIMIT 1) a;
    IF v_first IS DISTINCT FROM r.e1::date OR v_second IS DISTINCT FROM r.e2::date THEN
      v_bad := v_bad || format(' [alle %s %s am %s, genannt %s: erster Termin %s (erwartet %s), zweiter %s (erwartet %s)]',
                               r.intv, r.u, r.dom, r.named, v_first, r.e1, v_second, r.e2);
    END IF;
  END LOOP;
  IF v_bad <> '' THEN RAISE EXCEPTION 'FAIL erster Termin bei mehrmonatigem Rhythmus:%', v_bad; END IF;
  RAISE NOTICE 'PASS erster Termin = naechster Tag ab genanntem Datum, jeder Rhythmus';
END $$;
ROLLBACK;
