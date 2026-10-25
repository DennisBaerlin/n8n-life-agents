-- tests/db/career/test_fn_partial_date.sql
-- career.fn_partial_date(text): Roh-Datum in der Genauigkeit der Angabe (YYYY | YYYY-MM | YYYY-MM-DD) -> erster Tag
--   der Periode; alles andere -> NULL (Validator lehnt ab, Renderer laesst die Zeile weg).
BEGIN;

DO $$
BEGIN
  IF career.fn_partial_date('2014') IS DISTINCT FROM '2014-01-01'::date THEN RAISE EXCEPTION 'FAIL [YYYY]'; END IF;
  IF career.fn_partial_date('2014-09') IS DISTINCT FROM '2014-09-01'::date THEN RAISE EXCEPTION 'FAIL [YYYY-MM]'; END IF;
  IF career.fn_partial_date('2014-09-15') IS DISTINCT FROM '2014-09-15'::date THEN RAISE EXCEPTION 'FAIL [YYYY-MM-DD]'; END IF;
  IF career.fn_partial_date('2014-13') IS NOT NULL OR career.fn_partial_date('2014-02-30') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [ungueltig -> NULL]'; END IF;
  IF career.fn_partial_date('-12 years') IS NOT NULL OR career.fn_partial_date('seit 2014') IS NOT NULL
     OR career.fn_partial_date(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [kein Roh-Datum -> NULL]'; END IF;
  RAISE NOTICE 'PASS fn_partial_date [YYYY, YYYY-MM, YYYY-MM-DD, ungueltig/relativ/Freitext -> NULL]';
END $$;

ROLLBACK;
