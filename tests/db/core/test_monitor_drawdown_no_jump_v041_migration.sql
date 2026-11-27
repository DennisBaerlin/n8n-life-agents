-- tests/db/core/test_monitor_drawdown_no_jump_v041_migration.sql
-- core:V041 (echte Datei, zweimal) auf einer DB ohne das Gesetz "Absturz-Waechter ohne Sprung-Grenze": ein Bestands-
--   Absturz-Waechter mit max_jump_pct verliert die Grenze (sie hielt den Alarm stumm), ein Schwellen-Waechter behaelt seine;
--   danach lehnt die CHECK monitor_triggers_drawdown_no_jump die Kombination ab; zweiter Lauf = no-op.
BEGIN;

DO $$
BEGIN
  ALTER TABLE agent.monitor_triggers DROP CONSTRAINT IF EXISTS monitor_triggers_drawdown_no_jump;
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                      drawdown_pct, expected_unit, max_jump_pct, check_interval)
  VALUES ('__t_mon__', '__t_v041_dd__', 'drawdown', 'web_search', '{"prompt":"x"}'::jsonb, 20, 'EUR', 5, interval '1 day');
  INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                      comparator, threshold_value, expected_unit, max_jump_pct, check_interval)
  VALUES ('__t_mon__', '__t_v041_thr__', 'threshold', 'web_search', '{"prompt":"x"}'::jsonb, 'gte', 3, '%', 10, interval '1 day');
END $$;

\ir ../../../packages/core/db/migrations/V041__monitor_drawdown_no_jump.sql
\ir ../../../packages/core/db/migrations/V041__monitor_drawdown_no_jump.sql

DO $$
DECLARE v_ok boolean := false;
BEGIN
  IF (SELECT max_jump_pct FROM agent.monitor_triggers WHERE label = '__t_v041_dd__') IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL core:V041 [Absturz-Waechter behielt max_jump_pct]'; END IF;
  IF (SELECT max_jump_pct FROM agent.monitor_triggers WHERE label = '__t_v041_thr__') IS DISTINCT FROM 10 THEN
    RAISE EXCEPTION 'FAIL core:V041 [Schwellen-Waechter verlor max_jump_pct]'; END IF;
  BEGIN
    UPDATE agent.monitor_triggers SET max_jump_pct = 5 WHERE label = '__t_v041_dd__';
  EXCEPTION WHEN check_violation THEN v_ok := true;
  END;
  IF NOT v_ok THEN RAISE EXCEPTION 'FAIL core:V041 [CHECK fehlt nach der Migration]'; END IF;
  RAISE NOTICE 'PASS core:V041 [Bestands-Grenze am Absturz-Waechter entfernt, Schwelle unveraendert, CHECK aktiv, idempotent]';
END $$;

ROLLBACK;
