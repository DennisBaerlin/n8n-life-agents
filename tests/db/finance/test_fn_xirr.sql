-- tests/db/finance/test_fn_xirr.sql
-- finance.fn_xirr(dates, amounts, annualize) — geldgewichtete Rendite (XIRR, Act/365) gegen Lehrbuchwerte:
--   1) Microsoft-XIRR-Beispiel (5 Fluesse, 37,34 %), ein Jahr +10 % ueber ein Schaltjahr (366 Tage -> Act/365),
--      Verlust -20 %, Null-Rendite.
--   2) annualize = false: Rendite ueber die ganze Periode (nicht annualisiert, GIPS unter 1 Jahr); ein extrem kurzer
--      Zeitraum bleibt als Periodenrendite berechenbar, annualisiert NULL statt Ueberlauf.
--   3) gleiche Tage werden zusammengefasst; ohne + und - Fluss, ohne Zeitspanne, NULL-Werte, ungleiche Laengen -> NULL.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  v numeric;
BEGIN
  -- ===== 1) Lehrbuchwerte =====
  -- Microsoft-Support „XIRR-Funktion", Beispiel: Ergebnis 0,373362535
  v := finance.fn_xirr(ARRAY['2008-01-01', '2008-03-01', '2008-10-30', '2009-02-15', '2009-04-01']::date[],
                       ARRAY[-10000, 2750, 4250, 3250, 2750]::numeric[]);
  IF v IS NULL OR abs(v - 0.373362535) > 1e-8 THEN RAISE EXCEPTION 'FAIL [1a] Excel-Beispiel 0.373362535, got %', v; END IF;
  -- +10 % ueber 366 Tage (2020 ist Schaltjahr): Act/365 -> 1,1^(365/366) - 1, nicht 10 %
  v := finance.fn_xirr(ARRAY['2020-01-01', '2021-01-01']::date[], ARRAY[-1000, 1100]::numeric[]);
  IF v IS NULL OR abs(v - (power(1.1::numeric, 365.0 / 366) - 1)) > 1e-9 THEN
    RAISE EXCEPTION 'FAIL [1b] Act/365 ueber 366 Tage, got %', v; END IF;
  v := finance.fn_xirr(ARRAY['2021-01-01', '2022-01-01']::date[], ARRAY[-1000, 800]::numeric[]);
  IF v IS NULL OR abs(v - (-0.2)) > 1e-9 THEN RAISE EXCEPTION 'FAIL [1c] Verlust -20 %%, got %', v; END IF;
  v := finance.fn_xirr(ARRAY['2021-01-01', '2021-07-01', '2022-01-01']::date[], ARRAY[-500, -500, 1000]::numeric[]);
  IF v IS NULL OR abs(v) > 1e-9 THEN RAISE EXCEPTION 'FAIL [1d] Null-Rendite, got %', v; END IF;
  -- Reihenfolge der Eingabe egal (Fluesse nach Datum)
  v := finance.fn_xirr(ARRAY['2009-04-01', '2008-01-01', '2009-02-15', '2008-10-30', '2008-03-01']::date[],
                       ARRAY[2750, -10000, 3250, 4250, 2750]::numeric[]);
  IF v IS NULL OR abs(v - 0.373362535) > 1e-8 THEN RAISE EXCEPTION 'FAIL [1e] unsortierte Eingabe, got %', v; END IF;
  RAISE NOTICE 'PASS [1] XIRR Act/365: Excel-Beispiel, Schaltjahr, Verlust, Null';

  -- ===== 2) Periodenrendite (nicht annualisiert) =====
  v := finance.fn_xirr(ARRAY['2026-01-01', '2026-06-30']::date[], ARRAY[-800, 880]::numeric[], false);
  IF v IS NULL OR abs(v - 0.1) > 1e-9 THEN RAISE EXCEPTION 'FAIL [2a] Periodenrendite +10 %%, got %', v; END IF;
  -- zwei Einzahlungen: die Periodenrendite ist die annualisierte, auf die Periode zurueckgerechnet
  v := finance.fn_xirr(ARRAY['2026-01-01', '2026-03-01', '2026-06-30']::date[], ARRAY[-800, -100, 990]::numeric[], false);
  IF v IS NULL OR abs(v - (power(1 + finance.fn_xirr(ARRAY['2026-01-01', '2026-03-01', '2026-06-30']::date[],
                                                     ARRAY[-800, -100, 990]::numeric[]), 180 / 365.0) - 1)) > 1e-8 THEN
    RAISE EXCEPTION 'FAIL [2b] Periodenrendite = (1 + XIRR)^(Tage/365) - 1, got %', v; END IF;
  -- +900 % an einem Tag: annualisiert nicht darstellbar (NULL), als Periodenrendite 9,0
  IF finance.fn_xirr(ARRAY['2026-01-01', '2026-01-02']::date[], ARRAY[-100, 1000]::numeric[]) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [2c] Ueberlauf annualisiert -> NULL'; END IF;
  v := finance.fn_xirr(ARRAY['2026-01-01', '2026-01-02']::date[], ARRAY[-100, 1000]::numeric[], false);
  IF v IS NULL OR abs(v - 9) > 1e-9 THEN RAISE EXCEPTION 'FAIL [2d] Periodenrendite 9,0, got %', v; END IF;
  RAISE NOTICE 'PASS [2] Periodenrendite unter 1 Jahr, kein Ueberlauf';

  -- ===== 3) Gleiche Tage + nicht berechenbar =====
  v := finance.fn_xirr(ARRAY['2020-01-01', '2020-01-01', '2021-01-01', '2021-01-01']::date[],
                       ARRAY[-600, -400, 1000, 100]::numeric[]);
  IF v IS NULL OR abs(v - (power(1.1::numeric, 365.0 / 366) - 1)) > 1e-9 THEN
    RAISE EXCEPTION 'FAIL [3a] gleiche Tage zusammengefasst, got %', v; END IF;
  IF finance.fn_xirr(ARRAY['2020-01-01', '2021-01-01']::date[], ARRAY[-100, -50]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01', '2021-01-01']::date[], ARRAY[100, 50]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01', '2020-01-01']::date[], ARRAY[-100, 110]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01']::date[], ARRAY[-100]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01', '2021-01-01']::date[], ARRAY[-100]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01', NULL]::date[], ARRAY[-100, 110]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(ARRAY['2020-01-01', '2021-01-01']::date[], ARRAY[-100, NULL]::numeric[]) IS NOT NULL
     OR finance.fn_xirr(NULL, NULL) IS NOT NULL
     OR finance.fn_xirr('{}'::date[], '{}'::numeric[]) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3b] ohne +/- Fluss, ohne Zeitspanne, NULL, ungleiche Laenge -> NULL'; END IF;
  -- Fluesse, die sich am selben Tag aufheben, zaehlen nicht als Vorzeichen
  IF finance.fn_xirr(ARRAY['2020-01-01', '2020-01-01', '2021-01-01']::date[], ARRAY[-100, 100, 50]::numeric[]) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3c] aufgehobener Tagesfluss zaehlt nicht'; END IF;
  RAISE NOTICE 'PASS [3] gleiche Tage zusammengefasst; nicht berechenbar -> NULL';
END $$;
ROLLBACK;
