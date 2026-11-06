-- tests/db/finance/test_fn_schedule_dom_reason.sql
-- Testet fn_schedule_dom_reason: die EINE Adresse des Fehlertexts fuer einen ungueltigen Buchungstag
-- (gueltig: NULL, 1-28, -1 Monatsletzter, -2 vorletzter Tag). Domaene/CHECKs -> test_schedule_dom_domain.sql.
BEGIN;
DO $$
DECLARE v_reason TEXT;
BEGIN
  IF finance.fn_schedule_dom_reason(NULL) IS NOT NULL OR finance.fn_schedule_dom_reason(1) IS NOT NULL
     OR finance.fn_schedule_dom_reason(28) IS NOT NULL OR finance.fn_schedule_dom_reason(-1) IS NOT NULL
     OR finance.fn_schedule_dom_reason(-2) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL fn_schedule_dom_reason: gueltiger Tag mit Grund'; END IF;
  FOREACH v_reason IN ARRAY ARRAY[finance.fn_schedule_dom_reason(0), finance.fn_schedule_dom_reason(29),
                                  finance.fn_schedule_dom_reason(31), finance.fn_schedule_dom_reason(-3)] LOOP
    IF v_reason IS NULL OR v_reason NOT LIKE '%-1 (last day%' OR v_reason NOT LIKE '%-2 (second-to-last%' THEN
      RAISE EXCEPTION 'FAIL fn_schedule_dom_reason: ungueltiger Tag ohne vollstaendigen Grund, got %', v_reason; END IF;
  END LOOP;
  RAISE NOTICE 'PASS fn_schedule_dom_reason [NULL/1/28/-1/-2 gueltig; 0/29/31/-3 mit Grund inkl. -1/-2]';
END $$;
ROLLBACK;
