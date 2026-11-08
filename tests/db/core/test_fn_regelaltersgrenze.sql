-- tests/db/core/test_fn_regelaltersgrenze.sql
-- agent.fn_regelaltersgrenze(birth): Stufenplan der Regelaltersgrenze an jeder Jahrgangsgrenze (erfundene Geburtstage).
BEGIN;
DO $$
BEGIN
  IF agent.fn_regelaltersgrenze('1946-12-31') IS DISTINCT FROM DATE '2011-12-31' THEN
    RAISE EXCEPTION 'FAIL [1946 -> 65 Jahre], got %', agent.fn_regelaltersgrenze('1946-12-31'); END IF;
  IF agent.fn_regelaltersgrenze('1947-01-15') IS DISTINCT FROM DATE '2012-02-15' THEN
    RAISE EXCEPTION 'FAIL [1947 -> 65 Jahre + 1 Monat], got %', agent.fn_regelaltersgrenze('1947-01-15'); END IF;
  IF agent.fn_regelaltersgrenze('1958-06-01') IS DISTINCT FROM DATE '2024-06-01' THEN
    RAISE EXCEPTION 'FAIL [1958 -> 66 Jahre], got %', agent.fn_regelaltersgrenze('1958-06-01'); END IF;
  IF agent.fn_regelaltersgrenze('1959-03-10') IS DISTINCT FROM DATE '2025-05-10' THEN
    RAISE EXCEPTION 'FAIL [1959 -> 66 Jahre + 2 Monate], got %', agent.fn_regelaltersgrenze('1959-03-10'); END IF;
  IF agent.fn_regelaltersgrenze('1963-05-05') IS DISTINCT FROM DATE '2030-03-05' THEN
    RAISE EXCEPTION 'FAIL [1963 -> 66 Jahre + 10 Monate], got %', agent.fn_regelaltersgrenze('1963-05-05'); END IF;
  IF agent.fn_regelaltersgrenze('1964-01-01') IS DISTINCT FROM DATE '2031-01-01' THEN
    RAISE EXCEPTION 'FAIL [1964 -> 67 Jahre], got %', agent.fn_regelaltersgrenze('1964-01-01'); END IF;
  RAISE NOTICE 'PASS fn_regelaltersgrenze [Jahrgangsgrenzen 1946/47, 1958/59, 1963/64]';
END $$;
ROLLBACK;
