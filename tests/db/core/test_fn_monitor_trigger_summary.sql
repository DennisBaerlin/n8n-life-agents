-- tests/db/core/test_fn_monitor_trigger_summary.sql
-- WS4a: core.fn_monitor_trigger_summary(domain) -> (armed int, fired int) — publiziertes Lesefenster (D10),
--   damit der Advisor-Cron unter finance_ro die armed/fired-Zaehler aus agent.monitor_triggers lesen kann.
--   Prueft: Zaehlung je Domain (disabled zaehlt nirgends), leere/unbekannte Domain -> 0, + VF3 (finance_ro).
--   Muster: BEGIN…ROLLBACK; db_test hat kein seed_data -> monitor_triggers ist leer, wir seeden selbst.
BEGIN;

-- Minimal-Trigger (Typ recurring_info: nur label/trigger_type/check_interval noetig, keine Wert-Felder).
INSERT INTO agent.monitor_triggers (domain, label, trigger_type, check_interval, status) VALUES
  ('__t_fin__', 'a1', 'recurring_info', interval '1 day', 'armed'),
  ('__t_fin__', 'a2', 'recurring_info', interval '1 day', 'armed'),
  ('__t_fin__', 'f1', 'recurring_info', interval '1 day', 'fired'),
  ('__t_fin__', 'd1', 'recurring_info', interval '1 day', 'disabled'),
  ('__t_other__', 'o1', 'recurring_info', interval '1 day', 'armed');

DO $$
DECLARE v_armed int; v_fired int;
BEGIN
  SELECT armed, fired INTO v_armed, v_fired FROM core.fn_monitor_trigger_summary('__t_fin__');
  IF v_armed <> 2 THEN RAISE EXCEPTION 'FAIL [armed=%, erwartet 2]', v_armed; END IF;
  IF v_fired <> 1 THEN RAISE EXCEPTION 'FAIL [fired=%, erwartet 1]', v_fired; END IF;

  -- unbekannte/leere Domain -> 0/0 (count(*) FILTER liefert 0, keine NULL)
  SELECT armed, fired INTO v_armed, v_fired FROM core.fn_monitor_trigger_summary('__no_domain__');
  IF v_armed <> 0 OR v_fired <> 0 THEN RAISE EXCEPTION 'FAIL [leere Domain armed=%, fired=%]', v_armed, v_fired; END IF;

  RAISE NOTICE 'PASS core.fn_monitor_trigger_summary [armed/fired je Domain, disabled exkludiert, leer->0]';
END $$;

-- ---------- VF3 (D10): finance_ro liest ueber das Fenster, NICHT direkt agent.monitor_triggers ----------
DO $$
DECLARE v_armed int; v_blocked boolean := false;
BEGIN
  SET LOCAL ROLE finance_ro;
  SELECT armed INTO v_armed FROM core.fn_monitor_trigger_summary('__t_fin__');   -- EXECUTE-Grant greift
  BEGIN
    PERFORM 1 FROM agent.monitor_triggers WHERE domain = '__t_fin__';            -- muss scheitern (Isolation)
  EXCEPTION WHEN insufficient_privilege THEN v_blocked := true;
  END;
  RESET ROLE;

  IF v_armed <> 2 THEN RAISE EXCEPTION 'FAIL VF3 [finance_ro Fenster armed=%, erwartet 2]', v_armed; END IF;
  IF NOT v_blocked THEN RAISE EXCEPTION 'FAIL VF3 [finance_ro hat direkten SELECT auf agent.monitor_triggers]'; END IF;

  RAISE NOTICE 'PASS VF3 [finance_ro liest Trigger-Zaehler nur ueber das publizierte DEFINER-Fenster]';
END $$;

ROLLBACK;
