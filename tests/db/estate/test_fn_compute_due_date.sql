-- tests/db/estate/test_fn_compute_due_date.sql
-- WS-3 Fristen-Engine: Kalendertage/Wochen + KALENDARISCHE Monate (§§ 187/188 BGB) + unverzueglich.
BEGIN;

DO $$
BEGIN
  -- unverzueglich (NULL count) = am Anker-Tag faellig.
  IF estate.fn_compute_due_date('2024-05-10'::date, NULL, NULL, 'bayern') <> '2024-05-10'::date THEN
    RAISE EXCEPTION 'FAIL [unverzueglich <> Anker]'; END IF;

  -- Tage / Wochen.
  IF estate.fn_compute_due_date('2024-05-10'::date, 3, 'day', 'bayern')  <> '2024-05-13'::date THEN
    RAISE EXCEPTION 'FAIL [+3 Tage]'; END IF;
  IF estate.fn_compute_due_date('2024-05-10'::date, 6, 'week', 'bayern') <> '2024-06-21'::date THEN
    RAISE EXCEPTION 'FAIL [+6 Wochen: %]', estate.fn_compute_due_date('2024-05-10'::date, 6, 'week', 'bayern'); END IF;
  -- § 1944 BGB: 6 Wochen ab Kenntnis (15.01. -> 26.02.).
  IF estate.fn_compute_due_date('2024-01-15'::date, 6, 'week', 'bayern') <> '2024-02-26'::date THEN
    RAISE EXCEPTION 'FAIL [§1944 6 Wochen]'; END IF;

  -- Monate KALENDARISCH (§ 188 BGB: Tag gleicher Zahl; fehlt er -> Monatsende).
  --   15.01.2024 + 3 Monate = 15.04.2024 (§ 30 ErbStG).
  IF estate.fn_compute_due_date('2024-01-15'::date, 3, 'month', 'bayern') <> '2024-04-15'::date THEN
    RAISE EXCEPTION 'FAIL [+3 Monate normal]'; END IF;
  --   31.01.2024 + 1 Monat = 29.02.2024 (Schaltjahr, klemmt auf Monatsende).
  IF estate.fn_compute_due_date('2024-01-31'::date, 1, 'month', 'bayern') <> '2024-02-29'::date THEN
    RAISE EXCEPTION 'FAIL [31.01.+1M -> 29.02. Schaltjahr: %]', estate.fn_compute_due_date('2024-01-31'::date, 1, 'month', 'bayern'); END IF;
  --   31.01.2023 + 1 Monat = 28.02.2023 (kein Schaltjahr).
  IF estate.fn_compute_due_date('2023-01-31'::date, 1, 'month', 'bayern') <> '2023-02-28'::date THEN
    RAISE EXCEPTION 'FAIL [31.01.+1M -> 28.02. Nicht-Schaltjahr]'; END IF;

  -- business_day delegiert an fn_add_business_days.
  IF estate.fn_compute_due_date('2024-03-28'::date, 3, 'business_day', 'bayern') <> '2024-04-04'::date THEN
    RAISE EXCEPTION 'FAIL [business_day-Delegation]'; END IF;

  -- NULL-Anker -> NULL.
  IF estate.fn_compute_due_date(NULL, 3, 'day', 'bayern') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [NULL-Anker <> NULL]'; END IF;

  RAISE NOTICE 'PASS [fn_compute_due_date: unverzueglich/Tage/Wochen/Monate-kalendarisch/business_day/NULL]';
END $$;

ROLLBACK;
