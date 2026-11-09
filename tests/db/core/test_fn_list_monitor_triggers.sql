-- tests/db/core/test_fn_list_monitor_triggers.sql
-- core.fn_list_monitor_triggers(p_domain): publiziertes READ-ONLY-Lesefenster (SECURITY DEFINER, D10)
--   fuer das Dedup-Bewusstsein des Advisors beim Plan-Publish. Liefert label/trigger_type/status/
--   spec_summary der Trigger einer Domain; nur status IN ('armed','fired'); spec_summary AUSSCHLIESSLICH
--   aus typisierten Spalten (kein acquisition_spec/action_note-Echo). Leere Domain -> 0 Zeilen.
--   Rollen-Pfad (finance_ro kein permission denied + Negativ-Assert) deckt test_role_permissions.sql.
BEGIN;

DO $$
DECLARE
  v_cnt   INT;
  v_spec  TEXT;
BEGIN
  -- Seed: zwei armed + ein disabled (muss rausfallen) in einer Test-Domain
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
       comparator, threshold_value, expected_unit, check_interval, action_note)
  VALUES ('__lst__', 'Aluminium over 4000', 'threshold', 'web_search', '{"prompt":"GEHEIM nicht echoen"}',
          'gte', 4000, 'USD/t', interval '1 day', 'INTERNE NOTIZ nicht echoen');
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval)
  VALUES ('__lst__', 'Zinsbindung Ende', 'date', 'none', '2027-09-30', interval '7 days');
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, due_date, check_interval, status)
  VALUES ('__lst__', 'Disabled one', 'date', 'none', '2027-09-30', interval '7 days', 'disabled');

  INSERT INTO agent.plan_reminder_declines (domain, package, label, remind_on) VALUES ('__lst__', 'core', 'Abgelehnt', '2027-01-15');

  -- (1) liefert armed/fired, disabled und abgelehnte Eintraege
  SELECT COUNT(*) INTO v_cnt FROM core.fn_list_monitor_triggers('__lst__');
  IF v_cnt IS DISTINCT FROM 4 THEN
    RAISE EXCEPTION 'FAIL list [count]: erwartet 4, got %', v_cnt; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.fn_list_monitor_triggers('__lst__') WHERE label = 'Disabled one' AND status = 'disabled') THEN
    RAISE EXCEPTION 'FAIL list [disabled]'; END IF;
  IF NOT EXISTS (SELECT 1 FROM core.fn_list_monitor_triggers('__lst__') WHERE label = 'Abgelehnt' AND status = 'declined' AND spec_summary = 'date 2027-01-15') THEN
    RAISE EXCEPTION 'FAIL list [declined]'; END IF;

  -- (2) spec_summary kommt aus typisierten Spalten — NICHT aus acquisition_spec/action_note (Content-Guard M3)
  SELECT spec_summary INTO v_spec FROM core.fn_list_monitor_triggers('__lst__') WHERE label = 'Aluminium over 4000';
  IF v_spec NOT LIKE 'threshold gte 4000%' OR v_spec LIKE '%GEHEIM%' OR v_spec LIKE '%INTERNE%' THEN
    RAISE EXCEPTION 'FAIL list [content-guard]: spec_summary echote Freitext oder falsches Format: %', v_spec; END IF;

  -- (3) leere/unbekannte Domain -> 0 Zeilen
  SELECT COUNT(*) INTO v_cnt FROM core.fn_list_monitor_triggers('__nope__');
  IF v_cnt IS DISTINCT FROM 0 THEN
    RAISE EXCEPTION 'FAIL list [empty domain]: erwartet 0, got %', v_cnt; END IF;

  RAISE NOTICE 'PASS core.fn_list_monitor_triggers: 2 nicht-disabled, Content-Guard (kein Freitext-Echo), leere Domain 0';
END $$;

ROLLBACK;
