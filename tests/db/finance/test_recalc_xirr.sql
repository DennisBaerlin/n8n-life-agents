-- tests/db/finance/test_recalc_xirr.sql
-- Zweitrechnung Depot-Rendite (XIRR / IZF): Erwartungswerte mit einem eigenen Newton-Verfahren auf r (Startwert 10 %,
-- Abbruch 1e-14) in PowerShell gerechnet, nicht aus fn_xirr abgeschrieben (die loest nach dem Periodenfaktor).
-- Fachregel: Summe a_i / (1 + r)^((d_i - d_0) / 365) = 0, Act/365 wie Excel XIRR
--   (https://support.microsoft.com/en-us/office/xirr-function-de1242ec-6477-445b-b11b-a303ad9adc9d).
--   (1) Sparplan 12 x 100 EUR am Monatsersten 2025, Wert 1.250 am 31.12.2025 -> 7,7897996 % p.a.
--   (2) Schaltjahr: -1.000 am 01.07.2027, +1.100 am 01.07.2028 (366 Tage) -> 1,1^(365/366) - 1 = 9,9713586 %
--   (3) Verlust ueber den Jahreswechsel mit Nachkauf und Dividende -> -6,4905148 % p.a.
--   (4) Unter einem Jahr nicht annualisiert (GIPS): -1.000 / +1.020 -> 2 % ueber die Periode
--   (5) Gleiche Rendite unabhaengig vom Kalenderjahr: 365 Tage ohne Schalttag -> exakt 10 %
-- Toleranz 1e-8 (Abbruchkriterium der fn: Satz genauer als 1e-8).
BEGIN;

DO $$
DECLARE
  v numeric;
BEGIN
  v := finance.fn_xirr(
    ARRAY(SELECT make_date(2025, m, 1) FROM generate_series(1, 12) m) || DATE '2025-12-31',
    ARRAY(SELECT -100::numeric FROM generate_series(1, 12)) || 1250::numeric);
  IF v IS NULL OR abs(v - 0.077897996441620) > 1e-8 THEN RAISE EXCEPTION 'FAIL [1] Sparplan: erwartet 0.0778979964, got %', v; END IF;

  v := finance.fn_xirr(ARRAY['2027-07-01','2028-07-01']::date[], ARRAY[-1000, 1100]::numeric[]);
  IF v IS NULL OR abs(v - 0.099713585934141) > 1e-8 THEN RAISE EXCEPTION 'FAIL [2] Schaltjahr: erwartet 0.0997135859, got %', v; END IF;

  v := finance.fn_xirr(ARRAY['2025-10-15','2026-01-15','2026-04-30','2026-10-15']::date[],
                       ARRAY[-5000, -2000, 80, 6500]::numeric[]);
  IF v IS NULL OR abs(v - (-0.064905147614434)) > 1e-8 THEN RAISE EXCEPTION 'FAIL [3] Verlust: erwartet -0.0649051476, got %', v; END IF;

  v := finance.fn_xirr(ARRAY['2026-03-01','2026-05-30']::date[], ARRAY[-1000, 1020]::numeric[], false);
  IF v IS NULL OR abs(v - 0.02) > 1e-10 THEN RAISE EXCEPTION 'FAIL [4] Periode: erwartet 0.02, got %', v; END IF;

  v := finance.fn_xirr(ARRAY['2025-01-01','2026-01-01']::date[], ARRAY[-1000, 1100]::numeric[]);
  IF v IS NULL OR abs(v - 0.1) > 1e-10 THEN RAISE EXCEPTION 'FAIL [5] 365 Tage: erwartet 0.1, got %', v; END IF;

  RAISE NOTICE 'PASS XIRR-Zweitrechnung (Sparplan, Schaltjahr, Verlust ueber Jahreswechsel, Periode, 365 Tage)';
END $$;

ROLLBACK;
