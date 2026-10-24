-- tests/db/finance/test_fn_rate_precision_reason.sql
-- Rundungs-Paket 2026-10-23: Zinssatz/Tilgung passt in numeric(6,4) — > 4 Nachkommastellen kuerzte still, >= 100 warf
-- Overflow. 3.5 und 3.50000 (Skala 5, Wert 4-stellig darstellbar) sind gueltig; NULL = ok.
BEGIN;

DO $$
BEGIN
  IF finance.fn_rate_precision_reason(3.5, 'Rate') IS NOT NULL
     OR finance.fn_rate_precision_reason(3.50000, 'Rate') IS NOT NULL
     OR finance.fn_rate_precision_reason(3.1235, 'Rate') IS NOT NULL
     OR finance.fn_rate_precision_reason(NULL, 'Rate') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [ok]: 3.5 / 3.50000 / 3.1235 / NULL muessen gueltig sein';
  END IF;
  IF finance.fn_rate_precision_reason(3.12345, 'Rate') IS NULL THEN RAISE EXCEPTION 'FAIL [5 Stellen]'; END IF;
  IF finance.fn_rate_precision_reason(100, 'Rate') IS NULL OR finance.fn_rate_precision_reason(-100, 'Rate') IS NULL THEN
    RAISE EXCEPTION 'FAIL [>= 100]'; END IF;
  RAISE NOTICE 'PASS fn_rate_precision_reason [3.5/3.50000/3.1235 ok; 3.12345 und +-100 abgelehnt]';
END $$;

ROLLBACK;
