-- agent.fn_parse_decimal_or_null: deutsches Komma, Punkt, Leerzeichen; Unlesbares/leer -> NULL ohne RAISE.
BEGIN;
DO $$
BEGIN
  IF agent.fn_parse_decimal_or_null('1,5') IS DISTINCT FROM 1.5 THEN
    RAISE EXCEPTION 'FAIL parse_decimal [1,5]: %', agent.fn_parse_decimal_or_null('1,5'); END IF;
  IF agent.fn_parse_decimal_or_null(' 2.25 ') IS DISTINCT FROM 2.25 THEN
    RAISE EXCEPTION 'FAIL parse_decimal [2.25]: %', agent.fn_parse_decimal_or_null(' 2.25 '); END IF;
  IF agent.fn_parse_decimal_or_null('-3') IS DISTINCT FROM -3 THEN
    RAISE EXCEPTION 'FAIL parse_decimal [-3]: %', agent.fn_parse_decimal_or_null('-3'); END IF;
  IF agent.fn_parse_decimal_or_null('1.234,5') IS NOT NULL OR agent.fn_parse_decimal_or_null('etwa 5') IS NOT NULL
     OR agent.fn_parse_decimal_or_null('5 %') IS NOT NULL OR agent.fn_parse_decimal_or_null('NaN') IS NOT NULL
     OR agent.fn_parse_decimal_or_null('Infinity') IS NOT NULL OR agent.fn_parse_decimal_or_null('1e3') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL parse_decimal [unlesbar -> NULL]'; END IF;
  IF agent.fn_parse_decimal_or_null('') IS NOT NULL OR agent.fn_parse_decimal_or_null(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL parse_decimal [leer -> NULL]'; END IF;
  RAISE NOTICE 'PASS parse_decimal [Komma, Punkt, unlesbar/leer -> NULL]';
END $$;
ROLLBACK;
