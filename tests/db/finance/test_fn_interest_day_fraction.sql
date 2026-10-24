-- tests/db/finance/test_fn_interest_day_fraction.sql
-- Tageszaehl-Anteil (Jahresbruchteil) je Konvention. IMMUTABLE, reine Datums-Arithmetik. Die Erwartungen
-- sind EXTERN von Hand berechnet (NICHT aus der fn selbst abgeleitet -> kein Zirkelschluss):
--   30E/360 (deutsche Methode): tage = 360*(y2-y1) + 30*(m2-m1) + (d2'-d1'), wobei Tag 31 -> 30 UND der
--     letzte Februartag (28/29) -> 30; anteil = tage/360.
--   ACT/365: echte Kalendertage / 365.   ACT/360: echte Kalendertage / 360.
BEGIN;

DO $$
DECLARE v NUMERIC;
BEGIN
  -- ---- 30E/360 (deutsche Methode) ----
  -- 2026-01-01 -> 2026-02-01: 30*(2-1) + (1-1) = 30 -> 30/360 = 0.08333333
  v := ROUND(finance.fn_interest_day_fraction('2026-01-01','2026-02-01','30E/360'), 8);
  IF v IS DISTINCT FROM 0.08333333 THEN RAISE EXCEPTION 'FAIL [30E/360 month]: erwartet 0.08333333, got %', v; END IF;

  -- 2026-01-01 -> 2027-01-01: 360/360 = 1.0 exakt (volles Jahr)
  v := finance.fn_interest_day_fraction('2026-01-01','2027-01-01','30E/360');
  IF v IS DISTINCT FROM 1.0 THEN RAISE EXCEPTION 'FAIL [30E/360 year]: erwartet 1.0, got %', v; END IF;

  -- Tag-31-Regel + Februar-Regel: 2026-01-31 -> 2026-02-28 (d1 31->30, d2 Feb-Ende->30): 30/360
  v := ROUND(finance.fn_interest_day_fraction('2026-01-31','2026-02-28','30E/360'), 8);
  IF v IS DISTINCT FROM 0.08333333 THEN RAISE EXCEPTION 'FAIL [30E/360 jan-feb EoM]: erwartet 0.08333333 (Tag31+Feb-Regel), got %', v; END IF;

  -- Schaltjahr-Februar-Ende: 2024-02-29 -> 2024-03-31 (d1 Feb29-Ende->30, d2 31->30): 30/360
  v := ROUND(finance.fn_interest_day_fraction('2024-02-29','2024-03-31','30E/360'), 8);
  IF v IS DISTINCT FROM 0.08333333 THEN RAISE EXCEPTION 'FAIL [30E/360 leap feb EoM]: erwartet 0.08333333, got %', v; END IF;

  -- ---- ACT/365 (echte Tage / 365) ----
  -- 2026-01-01 -> 2026-02-01: 31 Tage -> 31/365 = 0.08493151
  v := ROUND(finance.fn_interest_day_fraction('2026-01-01','2026-02-01','ACT/365'), 8);
  IF v IS DISTINCT FROM 0.08493151 THEN RAISE EXCEPTION 'FAIL [ACT/365 jan]: erwartet 0.08493151, got %', v; END IF;

  -- Nicht-Schaltjahr volles Jahr: 365/365 = 1.0 exakt
  v := finance.fn_interest_day_fraction('2026-01-01','2027-01-01','ACT/365');
  IF v IS DISTINCT FROM 1.0 THEN RAISE EXCEPTION 'FAIL [ACT/365 year]: erwartet 1.0, got %', v; END IF;

  -- Schaltjahr volles Jahr: 366/365 = 1.00273973 (>1, die bekannte ACT/365-fixed-Eigenschaft)
  v := ROUND(finance.fn_interest_day_fraction('2024-01-01','2025-01-01','ACT/365'), 8);
  IF v IS DISTINCT FROM 1.00273973 THEN RAISE EXCEPTION 'FAIL [ACT/365 leap year]: erwartet 1.00273973, got %', v; END IF;

  -- Schaltjahr-Februar: 2024-02-01 -> 2024-03-01 = 29 Tage -> 29/365 = 0.07945205
  v := ROUND(finance.fn_interest_day_fraction('2024-02-01','2024-03-01','ACT/365'), 8);
  IF v IS DISTINCT FROM 0.07945205 THEN RAISE EXCEPTION 'FAIL [ACT/365 leap feb]: erwartet 0.07945205, got %', v; END IF;

  -- ---- ACT/360 (echte Tage / 360) ----
  -- 2026-01-01 -> 2026-02-01: 31/360 = 0.08611111
  v := ROUND(finance.fn_interest_day_fraction('2026-01-01','2026-02-01','ACT/360'), 8);
  IF v IS DISTINCT FROM 0.08611111 THEN RAISE EXCEPTION 'FAIL [ACT/360 jan]: erwartet 0.08611111, got %', v; END IF;

  -- Volles Jahr ueber 360: 365/360 = 1.01388889 (>1, die ACT/360-Eigenschaft)
  v := ROUND(finance.fn_interest_day_fraction('2026-01-01','2027-01-01','ACT/360'), 8);
  IF v IS DISTINCT FROM 1.01388889 THEN RAISE EXCEPTION 'FAIL [ACT/360 year]: erwartet 1.01388889, got %', v; END IF;

  -- Null-Periode (from=to) -> 0 in jeder Konvention
  IF finance.fn_interest_day_fraction('2026-05-05','2026-05-05','ACT/365') IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL [zero period]: erwartet 0';
  END IF;

  RAISE NOTICE 'PASS [fn_interest_day_fraction: 30E/360 + ACT/365 + ACT/360 gegen externe Referenzwerte]';
END $$;

ROLLBACK;
