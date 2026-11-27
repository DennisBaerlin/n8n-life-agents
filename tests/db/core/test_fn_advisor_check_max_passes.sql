-- tests/db/core/test_fn_advisor_check_max_passes.sql
-- core.fn_advisor_check_max_passes: die eine Lese-Adresse fuer advisor.check_max_passes (ohne Zeile -> 2, gesetzt -> Wert).
BEGIN;

DO $$
BEGIN
  DELETE FROM core.config WHERE category = 'advisor' AND key = 'check_max_passes';
  IF core.fn_advisor_check_max_passes() IS DISTINCT FROM 2 THEN
    RAISE EXCEPTION 'FAIL [ohne Zeile -> 2]: %', core.fn_advisor_check_max_passes(); END IF;
  PERFORM core.fn_config_seed('{"category":"advisor","key":"check_max_passes","value":"3","type":"integer","minimum":"1","maximum":"5","package":"core"}');
  IF core.fn_advisor_check_max_passes() IS DISTINCT FROM 3 THEN
    RAISE EXCEPTION 'FAIL [gesetzt -> 3]: %', core.fn_advisor_check_max_passes(); END IF;
  RAISE NOTICE 'PASS fn_advisor_check_max_passes [Rueckfall 2, gesetzter Wert]';
END $$;

ROLLBACK;
