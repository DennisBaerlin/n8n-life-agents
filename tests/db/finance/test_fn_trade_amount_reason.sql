-- tests/db/finance/test_fn_trade_amount_reason.sql
-- Rundungs-Paket 2026-10-23: EIN Guard fuer Kauf/Verkauf — Stueckzahl max. 8 Nachkommastellen (numeric(18,8) kuerzte
-- still), gebuchter Cent-Betrag > 0 (Mini-Kauf / Gebuehr frisst Erloes brach vorher am CHECK mit RAISE ab).
BEGIN;

DO $$
BEGIN
  IF finance.fn_trade_amount_reason(0.06127493, 3322.2042) IS NOT NULL
     OR finance.fn_trade_amount_reason(1, 0.005) IS NOT NULL THEN       -- 0.005 rundet auf 0.01 -> ok
    RAISE EXCEPTION 'FAIL [ok]: gueltige Werte duerfen keinen Grund liefern';
  END IF;
  IF finance.fn_trade_amount_reason(0.123456789, 10) IS NULL THEN RAISE EXCEPTION 'FAIL [stueck]: > 8 Stellen'; END IF;
  IF finance.fn_trade_amount_reason(0.00000001, 0.000001) IS NULL THEN RAISE EXCEPTION 'FAIL [mini]: < 1 Cent'; END IF;
  IF finance.fn_trade_amount_reason(0.01, 0.3 - 1) IS NULL THEN RAISE EXCEPTION 'FAIL [sell]: Gebuehr >= Erloes'; END IF;
  IF finance.fn_trade_amount_reason(NULL, NULL) IS NOT NULL THEN RAISE EXCEPTION 'FAIL [null]'; END IF;
  RAISE NOTICE 'PASS fn_trade_amount_reason [ok / > 8 Stellen / < 1 Cent / Gebuehr >= Erloes / NULL]';
END $$;

ROLLBACK;
