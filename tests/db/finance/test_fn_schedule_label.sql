-- tests/db/finance/test_fn_schedule_label.sql
-- Testet finance.fn_schedule_label: Rhythmus einer Dauerzahlung in Klartext (Livebefund 2026-10-27: ein woechentlicher
--   Plan mit festen Bank-Tagen wurde als "monatlich" gelesen). Feste Tage nennen immer Anzahl je Monat + Tage.
BEGIN;

DO $$
DECLARE
  v TEXT;
BEGIN
  v := finance.fn_schedule_label('month', 1::smallint, NULL, '{2,9,16,23}'::smallint[]);
  IF v IS DISTINCT FROM 'weekly (4 times a month, on day 2, 9, 16, 23)' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [4 feste Tage]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, NULL, '{1,15}'::smallint[]);
  IF v IS DISTINCT FROM 'twice a month (on day 1, 15)' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [2 feste Tage]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, NULL, '{1,10,20}'::smallint[]);
  IF v IS DISTINCT FROM '3 times a month (on day 1, 10, 20)' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [3 feste Tage]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, 1::smallint, NULL);
  IF v IS DISTINCT FROM 'monthly, on day 1' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [monatlich am 1.]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, (-1)::smallint, NULL);
  IF v IS DISTINCT FROM 'monthly, on the last day' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [Monatsletzter]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, (-2)::smallint, NULL);
  IF v IS DISTINCT FROM 'monthly, on the second-to-last day' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [vorletzter Tag]: %', v; END IF;

  v := finance.fn_schedule_label('month', 1::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'monthly' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [monatlich ohne Tag]: %', v; END IF;

  v := finance.fn_schedule_label('month', 3::smallint, 15::smallint, NULL);
  IF v IS DISTINCT FROM 'quarterly, on day 15' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [quartalsweise]: %', v; END IF;

  v := finance.fn_schedule_label('month', 2::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'every 2 months' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [alle 2 Monate]: %', v; END IF;

  v := finance.fn_schedule_label('week', 1::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'weekly' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [echte 7 Tage]: %', v; END IF;

  v := finance.fn_schedule_label('week', 2::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'every 2 weeks' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [alle 2 Wochen]: %', v; END IF;

  v := finance.fn_schedule_label('year', 1::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'yearly' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [jaehrlich]: %', v; END IF;

  v := finance.fn_schedule_label('day', 1::smallint, NULL, NULL);
  IF v IS DISTINCT FROM 'daily' THEN
    RAISE EXCEPTION 'FAIL fn_schedule_label [taeglich]: %', v; END IF;

  RAISE NOTICE 'PASS fn_schedule_label [feste Tage, Monat/Quartal/Woche/Jahr/Tag]';

  -- active_recurring_payments traegt den Rhythmus (eine Quelle fuer den Agenten)
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'finance' AND table_name = 'active_recurring_payments' AND column_name = 'rhythm') THEN
    RAISE EXCEPTION 'FAIL active_recurring_payments: Spalte rhythm fehlt'; END IF;
  RAISE NOTICE 'PASS active_recurring_payments [Spalte rhythm]';
END $$;

ROLLBACK;
