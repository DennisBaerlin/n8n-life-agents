-- ============================================================
-- V041 (core) — Gesetz "Absturz-Waechter ohne Sprung-Grenze" auf Bestands-DBs
--   Ein Absturz IST ein grosser Sprung: fn_validate_observation (Stufe 4) verwirft jeden Wert, der mehr als max_jump_pct
--   vom letzten sauberen abweicht, und ein drawdown-Waechter mit Grenze schluckt deshalb jeden abrupten Absturz. Die Inline-CHECK aus
--   agent.monitor_init.sql gilt nur fuer frische DBs; diese Migration nullt die Grenze an Bestands-Absturz-Waechtern
--   (sie konnte dort nur Alarme verschlucken) und legt die benannte CHECK an. Andere Typen unveraendert.
--   Frische DB = no-op. Re-run-sicher. Test: tests/db/core/test_monitor_drawdown_no_jump_v041_migration.sql
-- ============================================================
UPDATE agent.monitor_triggers SET max_jump_pct = NULL
 WHERE trigger_type = 'drawdown' AND max_jump_pct IS NOT NULL;

DO $$ BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'agent.monitor_triggers'::regclass
                      AND conname  = 'monitor_triggers_drawdown_no_jump') THEN
        ALTER TABLE agent.monitor_triggers ADD CONSTRAINT monitor_triggers_drawdown_no_jump
            CHECK (trigger_type <> 'drawdown' OR max_jump_pct IS NULL);
    END IF;
END $$;
