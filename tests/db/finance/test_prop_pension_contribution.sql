-- tests/db/finance/test_prop_pension_contribution.sql
-- Eigenschafts-Test: den Beitrag einer Vorsorge aendern (fn_set_pension contribution_amount), gegen die Vorschau.
--   Q1 kein offener Termin geht verloren oder kommt dazu (gleiche Faelligkeiten vor und nach der Aenderung)
--   Q2 Termine vor dem gemeldeten first_due behalten den alten Betrag (auch ueberfaellige offene), ab first_due gilt der neue
--   Q3 ein gebuchter oder uebersprungener Termin wird nicht wieder offen
--   Q4 Rueckgabe, Vertrags-Sicht am Stichtag und Monatsrechnung nennen denselben Beitrag
--   Q5 aendern und zurueck: die Vorschau ist wieder die von vorher
--   Q6 mit schon geplanter Aenderung: first_due ist der Termin, ab dem der neue Betrag wirklich gilt
-- Raster: Start (lange her, kuerzlich, kuenftig) x Erledigtes (nichts, gebucht, gebucht + Rest uebersprungen) x Stichtag (leer, +45, +100).
BEGIN;

CREATE FUNCTION pg_temp.snap(p_head int, p_t date) RETURNS TABLE(due_date date, amount numeric) LANGUAGE sql STABLE AS $$
  SELECT u.due_date, u.amount FROM finance.fn_upcoming_payments(p_t - 400, p_t + 400) u
   WHERE u.recurring_payment_id IN (SELECT finance.fn_recurring_lineage(p_head));
$$;

DO $$
DECLARE
  v_t DATE := current_date;
  v_res JSONB; v_giro INT; v_pen INT; v_rp INT; v_head INT; v_n INT := 0;
  v_start INT; v_done TEXT; v_eff INT; v_first DATE; v_bad TEXT;
BEGIN
  SELECT (finance.fn_create_account('{"name":"__ppc_giro__","account_type":"cash","account_holder":"Test"}'::jsonb)->>'account_id')::int INTO v_giro;
  PERFORM finance.fn_book_transaction(jsonb_build_object('account_id',v_giro,'amount',9000,'direction','inflow','transaction_date',v_t - 200));

  FOREACH v_start IN ARRAY ARRAY[-100, -40, -5, 12] LOOP
  FOREACH v_done IN ARRAY ARRAY['none', 'booked', 'booked+skipped'] LOOP
  FOREACH v_eff IN ARRAY ARRAY[0, 45, 100] LOOP
    CONTINUE WHEN v_start > 0 AND v_done <> 'none';
    BEGIN
      v_res := finance.fn_create_pension(jsonb_build_object('name','__ppc_pen__','pension_type','private','contribution_amount',150,
        'debit_account_id',v_giro,'first_payment_date',v_t + v_start));
      v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      IF v_done <> 'none' THEN
        v_res := finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t + v_start));
        IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL Q setup book: %', v_res; END IF;
      END IF;
      IF v_done = 'booked+skipped' THEN
        PERFORM finance.fn_skip_recurring_occurrence(jsonb_build_object('recurring_payment_id',o.recurring_payment_id,'due_date',o.due_date))
          FROM finance.fn_recurring_due_open(v_t - 1) o WHERE o.recurring_payment_id = v_rp;
      END IF;
      CREATE TEMP TABLE ppc_before ON COMMIT DROP AS SELECT * FROM pg_temp.snap(v_rp, v_t);

      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',210)
                 || CASE WHEN v_eff > 0 THEN jsonb_build_object('effective_from', v_t + v_eff) ELSE '{}'::jsonb END);
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL Q [start % done % eff %]: abgelehnt %', v_start, v_done, v_eff, v_res; END IF;
      v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
      v_first := (v_res->>'first_due')::date;

      -- Q1
      SELECT string_agg(d::text, ',') INTO v_bad FROM (
        (SELECT due_date AS d FROM ppc_before EXCEPT SELECT due_date FROM pg_temp.snap(v_head, v_t))
        UNION ALL
        (SELECT due_date FROM pg_temp.snap(v_head, v_t) EXCEPT SELECT due_date FROM ppc_before)) x;
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL Q1 [start % done % eff %]: Termine verloren oder dazugekommen: %', v_start, v_done, v_eff, v_bad; END IF;
      -- Q2
      IF v_first IS NULL OR (v_eff > 0 AND v_first < v_t + v_eff) THEN
        RAISE EXCEPTION 'FAIL Q2 [start % done % eff %]: first_due % (Rueckgabe %)', v_start, v_done, v_eff, v_first, v_res; END IF;
      SELECT string_agg(s.due_date || '=' || s.amount, ',') INTO v_bad FROM pg_temp.snap(v_head, v_t) s
       WHERE s.amount IS DISTINCT FROM (CASE WHEN s.due_date < v_first THEN -150 ELSE -210 END);
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL Q2 [start % done % eff %]: first_due %, falscher Betrag an %', v_start, v_done, v_eff, v_first, v_bad; END IF;
      -- ein ueberfaelliger offener Termin darf nicht teurer werden: ohne genannten Stichtag liegt first_due nie vor heute,
      -- ausser es war noch nie etwas faellig (Korrektur direkt nach der Anlage)
      IF v_eff = 0 AND v_first < v_t AND EXISTS (SELECT 1 FROM ppc_before b WHERE b.due_date < v_t) THEN
        RAISE EXCEPTION 'FAIL Q2 [start % done %]: neuer Beitrag gilt rueckwirkend ab %', v_start, v_done, v_first; END IF;
      -- Q3
      IF v_done <> 'none' AND EXISTS (SELECT 1 FROM pg_temp.snap(v_head, v_t) s WHERE s.due_date = v_t + v_start) THEN
        RAISE EXCEPTION 'FAIL Q3 [start % done % eff %]: gebuchter Termin wieder offen', v_start, v_done, v_eff; END IF;
      -- Q4
      IF (v_res->>'contribution_amount')::numeric IS DISTINCT FROM 210 OR (v_res->>'monthly_contribution')::numeric IS DISTINCT FROM 210
         OR (SELECT abs(r.amount) FROM finance.recurring_payments r WHERE r.id = finance.fn_recurring_current(v_head, v_first)) IS DISTINCT FROM 210
         OR (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen)
              IS DISTINCT FROM (SELECT abs(r.amount) FROM finance.recurring_payments r WHERE r.id = finance.fn_recurring_current(v_head, v_t)) THEN
        RAISE EXCEPTION 'FAIL Q4 [start % done % eff %]: Rueckgabe %, Sicht %', v_start, v_done, v_eff, v_res,
          (SELECT contribution_amount FROM finance.pension_overview WHERE id = v_pen); END IF;

      -- Q5 zurueck auf den alten Beitrag zum selben Stichtag
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',150,'effective_from',v_first));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN
        RAISE EXCEPTION 'FAIL Q5 [start % done % eff %]: zurueck abgelehnt %', v_start, v_done, v_eff, v_res; END IF;
      v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
      SELECT string_agg(x.d || '=' || x.a, ',') INTO v_bad FROM (
        (SELECT due_date AS d, amount AS a FROM ppc_before EXCEPT SELECT due_date, amount FROM pg_temp.snap(v_head, v_t))
        UNION ALL
        (SELECT due_date, amount FROM pg_temp.snap(v_head, v_t) EXCEPT SELECT due_date, amount FROM ppc_before)) x;
      IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'FAIL Q5 [start % done % eff %]: nach aendern und zurueck weicht die Vorschau ab: %', v_start, v_done, v_eff, v_bad; END IF;
      IF (SELECT -sum(m.monthly_equivalent) FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head)))
           IS DISTINCT FROM (CASE WHEN v_start > 0 THEN NULL ELSE 150 END)
         AND v_start <= 0 THEN
        RAISE EXCEPTION 'FAIL Q5 [start % done % eff %]: Monatsrechnung % statt 150', v_start, v_done, v_eff,
          (SELECT -sum(m.monthly_equivalent) FROM finance.monthly_cashflow_overview m WHERE m.id IN (SELECT finance.fn_recurring_lineage(v_head))); END IF;

      DROP TABLE ppc_before;
      v_n := v_n + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP; END LOOP; END LOOP;

  -- Q6 geplante Aenderung vorhanden (ab +100 auf 300), dann neuer Beitrag ohne und mit Stichtag
  FOREACH v_eff IN ARRAY ARRAY[0, 45, 130] LOOP
    BEGIN
      v_res := finance.fn_create_pension(jsonb_build_object('name','__ppc_pen__','pension_type','private','contribution_amount',150,
        'debit_account_id',v_giro,'first_payment_date',v_t - 40));
      v_pen := (v_res->>'pension_id')::int; v_rp := (v_res->>'recurring_payment_id')::int;
      PERFORM finance.fn_book_recurring_occurrence(jsonb_build_object('recurring_payment_id',v_rp,'due_date',v_t - 40));
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',300,'effective_from',v_t + 100));
      IF (v_res->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL Q6 setup: %', v_res; END IF;
      CREATE TEMP TABLE ppc_before ON COMMIT DROP AS SELECT * FROM pg_temp.snap(v_rp, v_t);
      v_res := finance.fn_set_pension(jsonb_build_object('pension_id',v_pen,'contribution_amount',250)
                 || CASE WHEN v_eff > 0 THEN jsonb_build_object('effective_from', v_t + v_eff) ELSE '{}'::jsonb END);
      v_head := (SELECT recurring_payment_id FROM finance.pension WHERE id = v_pen);
      v_first := (v_res->>'first_due')::date;
      IF (v_res->>'ok')::boolean IS TRUE THEN
        SELECT string_agg(s.due_date || '=' || s.amount, ',') INTO v_bad FROM pg_temp.snap(v_head, v_t) s
          LEFT JOIN ppc_before b ON b.due_date = s.due_date
         WHERE b.due_date IS NULL OR s.amount IS DISTINCT FROM (CASE WHEN s.due_date < v_first THEN b.amount ELSE -250 END);
        IF v_bad IS NOT NULL OR v_first IS NULL OR (v_eff > 0 AND v_first < v_t + v_eff)
           OR (SELECT count(*) FROM pg_temp.snap(v_head, v_t)) <> (SELECT count(*) FROM ppc_before) THEN
          RAISE EXCEPTION 'FAIL Q6 [eff %]: first_due %, abweichend %, Rueckgabe %', v_eff, v_first, v_bad, v_res; END IF;
      ELSIF v_res->>'reason' IS NULL THEN
        RAISE EXCEPTION 'FAIL Q6 [eff %]: Ablehnung ohne Grund %', v_eff, v_res;
      ELSIF EXISTS ((SELECT * FROM ppc_before EXCEPT SELECT * FROM pg_temp.snap(v_head, v_t))) THEN
        RAISE EXCEPTION 'FAIL Q6 [eff %]: Ablehnung hat die Vorschau veraendert', v_eff;
      END IF;
      RAISE NOTICE 'PASS-INFO Q6 [eff %]: ok=% first_due=% reason=%', v_eff, v_res->>'ok', v_first, left(v_res->>'reason', 120);
      DROP TABLE ppc_before;
      v_n := v_n + 1;
      RAISE EXCEPTION USING ERRCODE = 'RS000', MESSAGE = 'rollback';
    EXCEPTION WHEN SQLSTATE 'RS000' THEN NULL;
    END;
  END LOOP;

  IF v_n <> 33 THEN RAISE EXCEPTION 'FAIL prop pension contribution: nur % von 33 Faellen gelaufen', v_n; END IF;
  RAISE NOTICE 'PASS prop pension contribution [% Faelle, Q1-Q6]', v_n;
END $$;

ROLLBACK;
