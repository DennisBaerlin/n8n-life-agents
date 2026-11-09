-- tests/db/core/test_fn_period_reminder_date.sql
-- core.fn_period_reminder_date: feste Zeitformen -> Datum, Jahreswechsel, NULL-Faelle, Bezugstag eines aelteren Texts.
BEGIN;
DO $$
DECLARE
  f CONSTANT DATE := '2026-11-09';
BEGIN
  IF core.fn_period_reminder_date('next_year', f) <> '2027-02-01' THEN RAISE EXCEPTION 'FAIL next_year'; END IF;
  IF core.fn_period_reminder_date('next_quarter', f) <> '2027-02-01' THEN RAISE EXCEPTION 'FAIL next_quarter Q4'; END IF;
  IF core.fn_period_reminder_date('next_quarter', DATE '2026-02-10') <> '2026-05-01' THEN RAISE EXCEPTION 'FAIL next_quarter Q1'; END IF;
  IF core.fn_period_reminder_date('next_month', f) <> '2026-12-15' THEN RAISE EXCEPTION 'FAIL next_month'; END IF;
  IF core.fn_period_reminder_date('next_month', DATE '2026-12-20') <> '2027-01-15' THEN RAISE EXCEPTION 'FAIL next_month Dez'; END IF;
  IF core.fn_period_reminder_date('this_year', f) <> '2026-12-01' THEN RAISE EXCEPTION 'FAIL this_year'; END IF;
  IF core.fn_period_reminder_date('this_year', DATE '2026-12-20') IS NOT NULL THEN RAISE EXCEPTION 'FAIL this_year Dez'; END IF;
  IF core.fn_period_reminder_date('in_3_months', f) <> '2027-02-09' THEN RAISE EXCEPTION 'FAIL in_N'; END IF;
  IF core.fn_period_reminder_date('in_x_months', f) IS NOT NULL THEN RAISE EXCEPTION 'FAIL in_x'; END IF;
  IF core.fn_period_reminder_date('irgendwann', f) IS NOT NULL THEN RAISE EXCEPTION 'FAIL unbekannt'; END IF;
  IF core.fn_period_reminder_date(NULL, f) IS NOT NULL THEN RAISE EXCEPTION 'FAIL NULL'; END IF;
  -- Text aus dem Dezember, im Januar gelesen: Bezugstag bleibt der Dezember
  IF core.fn_period_reminder_date('next_year', DATE '2026-12-28') <> '2027-02-01' THEN RAISE EXCEPTION 'FAIL Bezugstag'; END IF;
  -- Default: heute
  IF core.fn_period_reminder_date('in_1_months') IS NULL THEN RAISE EXCEPTION 'FAIL Default'; END IF;
END $$;
ROLLBACK;
