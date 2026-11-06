-- tests/db/finance/test_fn_schedule_occurrences.sql
-- fn_schedule_occurrences = das EINE Faelligkeitsraster (WP2 "Finanzen schlank"): fn_recurring_due_open und die
-- Restschuld-Vorschau fn_loan_balance_at rechnen ueber dieselbe reine fn. Faelle (Reviewer-Matrix):
--   (1) Monat, Tag aus dem Anker 31. -> Monatsend-Clamping gegen den ANKER, nicht schrittweise (31.01. -> 28.02. -> 31.03.)
--   (2) Monatsletzter (-1) und vorletzter Tag (-2)
--   (3) fester Tag 15, interval 3 (Quartal)
--   (4) feste Monatstage {2,16}; leere Liste '{}' -> keine Termine
--   (5) Jahr mit Anker 29.02. (Clamping auf 28.02. in Nicht-Schaltjahren)
--   (6) Tag/Woche mit interval > 1
--   (7) Anker nach dem Ende -> leer; p_from schneidet vorne ab
--   (8) Paritaet: fn_recurring_due_open liefert fuer eine rp genau das Raster ab valid_from
--   (9) IMMUTABLE ist ehrlich (provolatile = 'i') und LANGUAGE sql (inlinebar)
BEGIN;

DO $$
DECLARE
  v_got date[];
  v_acc int;
  v_rp  int;
BEGIN
  -- (1) Anker 31.01., monatlich ohne Tag -> Clamping je Monat gegen den Anker
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-31', 1, 'month', NULL, NULL, '2026-01-01', '2026-04-30') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-01-31','2026-02-28','2026-03-31','2026-04-30']::date[] THEN
    RAISE EXCEPTION 'FAIL [1 clamp]: %', v_got; END IF;

  -- (2) -1 und -2
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-10', 1, 'month', -1::smallint, NULL, '2026-01-01', '2026-03-31') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-01-31','2026-02-28','2026-03-31']::date[] THEN
    RAISE EXCEPTION 'FAIL [2 dom -1]: %', v_got; END IF;
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-10', 1, 'month', -2::smallint, NULL, '2026-01-01', '2026-03-31') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-01-30','2026-02-27','2026-03-30']::date[] THEN
    RAISE EXCEPTION 'FAIL [2 dom -2]: %', v_got; END IF;

  -- (3) Quartal am 15.
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-15', 3, 'month', 15::smallint, NULL, '2026-01-01', '2026-12-31') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-01-15','2026-04-15','2026-07-15','2026-10-15']::date[] THEN
    RAISE EXCEPTION 'FAIL [3 quarter]: %', v_got; END IF;

  -- (4) feste Monatstage
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-02', 1, 'month', NULL, '{2,16}'::smallint[], '2026-01-01', '2026-02-28') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-01-02','2026-01-16','2026-02-02','2026-02-16']::date[] THEN
    RAISE EXCEPTION 'FAIL [4 days]: %', v_got; END IF;
  IF EXISTS (SELECT 1 FROM finance.fn_schedule_occurrences('2026-01-02', 1, 'month', NULL, '{}'::smallint[], '2026-01-01', '2026-02-28')) THEN
    RAISE EXCEPTION 'FAIL [4 empty days]: erwartet keine Termine'; END IF;

  -- (5) Jahresanker 29.02.
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2024-02-29', 1, 'year', NULL, NULL, '2024-01-01', '2028-12-31') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2024-02-29','2025-02-28','2026-02-28','2027-02-28','2028-02-29']::date[] THEN
    RAISE EXCEPTION 'FAIL [5 leap]: %', v_got; END IF;

  -- (6) alle 3 Tage / alle 2 Wochen
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-03-01', 3, 'day', NULL, NULL, '2026-03-01', '2026-03-10') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-03-01','2026-03-04','2026-03-07','2026-03-10']::date[] THEN
    RAISE EXCEPTION 'FAIL [6 day]: %', v_got; END IF;
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-03-02', 2, 'week', NULL, NULL, '2026-03-01', '2026-03-31') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-03-02','2026-03-16','2026-03-30']::date[] THEN
    RAISE EXCEPTION 'FAIL [6 week]: %', v_got; END IF;

  -- (7) Anker nach dem Ende -> leer; p_from schneidet vorne ab (Anker bleibt Rhythmus)
  IF EXISTS (SELECT 1 FROM finance.fn_schedule_occurrences('2027-01-01', 1, 'month', NULL, NULL, '2026-01-01', '2026-12-31')) THEN
    RAISE EXCEPTION 'FAIL [7 anchor > until]'; END IF;
  v_got := ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-05', 1, 'month', NULL, NULL, '2026-03-01', '2026-04-30') d ORDER BY d);
  IF v_got IS DISTINCT FROM ARRAY['2026-03-05','2026-04-05']::date[] THEN
    RAISE EXCEPTION 'FAIL [7 from]: %', v_got; END IF;

  -- (8) Paritaet mit fn_recurring_due_open (eine rp, nichts gebucht, valid_from schneidet vorne ab)
  SELECT (finance.fn_create_account('{"name":"__test_so_giro__","account_type":"cash"}'::jsonb)->>'account_id')::int INTO v_acc;
  v_rp := finance.fn_add_recurring_payment(v_acc, -50, '__test_so_rp__', 1::smallint, 'month'::finance.schedule_unit,
                                           -2::smallint, '2026-01-10', '2026-02-15', NULL, NULL, NULL);
  v_got := ARRAY(SELECT due_date FROM finance.fn_recurring_due_open('2026-01-01', '2026-05-31') WHERE recurring_payment_id = v_rp ORDER BY 1);
  IF v_got IS DISTINCT FROM ARRAY(SELECT d FROM finance.fn_schedule_occurrences('2026-01-10', 1, 'month', -2::smallint, NULL, '2026-02-15', '2026-05-31') d ORDER BY d) THEN
    RAISE EXCEPTION 'FAIL [8 parity]: due_open=%', v_got; END IF;

  -- (9) Volatilitaet + Sprache
  IF (SELECT provolatile::text || '/' || l.lanname FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang
      WHERE p.oid = 'finance.fn_schedule_occurrences(date,int,finance.schedule_unit,smallint,smallint[],date,date)'::regprocedure)
     IS DISTINCT FROM 'i/sql' THEN
    RAISE EXCEPTION 'FAIL [9 volatility]'; END IF;

  RAISE NOTICE 'PASS fn_schedule_occurrences (Clamping, -1/-2, Quartal, feste Tage, 29.02., Tag/Woche, Grenzen, Paritaet, IMMUTABLE sql)';
END $$;

ROLLBACK;
