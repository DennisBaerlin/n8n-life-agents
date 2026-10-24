-- tests/db/core/test_core_only.sql
-- Phase B Pflicht-Testfall: der Core laeuft OHNE jedes Domaenen-Paket (Core-only-Install bzw. nach einer
-- `--keep-data`-Deinstallation, bei der Registry-/Monitor-Zeilen auf ein fehlendes Paket zeigen).
-- Im Test-TX werden ALLE Paket-Schemas gedroppt (DDL ist transaktional und kommt per
-- ROLLBACK zurueck); die Registry-Zeilen bleiben stehen (= der verwaiste Zustand). Danach muessen alle
-- generisch umgebauten Core-Pfade fehlerfrei laufen:
--   Monitor-Heartbeat (verwaister fx-Trigger wird GEPARKT, kein RAISE, kein fail_streak), Probe + Anlage einer
--   fehlenden Paket-Methode ({ok:false}), Lern-Sammler, E2E-Cleanup, Onboarding-Reset, Werkszustand-Reset.
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

INSERT INTO core.package_registry (package, status) VALUES
  ('finance', 'active'), ('career', 'active'), ('estate', 'active'), ('paperless', 'active')
ON CONFLICT (package) DO UPDATE SET status = 'active';
INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
VALUES ('fx_rate', 'finance.fn_monitor_acquire_fx_rate', 'finance.fn_monitor_validate_fx_rate', 'finance')
ON CONFLICT (method) DO UPDATE SET acquire_fn = excluded.acquire_fn, validate_fn = excluded.validate_fn, package = 'finance';
INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
INSERT INTO agent.monitor_triggers (domain, label, trigger_type, acquisition_method, acquisition_spec,
                                    comparator, threshold_value, check_interval, next_check_at)
VALUES ('general', 'zz orphan fx', 'threshold', 'fx_rate', '{"base": "EUR", "quote": "KRW"}', 'gte', 1400,
        interval '1 day', now() - interval '1 hour');

DROP SCHEMA finance CASCADE;
DROP SCHEMA career CASCADE;
DROP SCHEMA estate CASCADE;
DROP SCHEMA paperless CASCADE;

DO $$
DECLARE
  r     jsonb;
  v_row agent.monitor_triggers%ROWTYPE;
BEGIN
  -- Monitor-Heartbeat: verwaister fx-Trigger geparkt (vorher: undefined_table -> ganzer Lauf tot)
  r := agent.fn_monitor_evaluate('{}'::jsonb);
  SELECT * INTO v_row FROM agent.monitor_triggers WHERE label = 'zz orphan fx';
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR v_row.fail_streak <> 0 OR v_row.last_checked_at IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL core-only [Heartbeat]: r=% streak=% checked=%', r, v_row.fail_streak, v_row.last_checked_at;
  END IF;
  IF EXISTS (SELECT 1 FROM agent.fn_monitor_due(now()) d WHERE d.label = 'zz orphan fx') THEN
    RAISE EXCEPTION 'FAIL core-only [Heartbeat]: verwaister Trigger ist faellig'; END IF;

  -- Probe + Anlage einer fehlenden Paket-Methode -> {ok:false}, kein RAISE
  r := agent.fn_monitor_probe('{"acquisition_method": "fx_rate", "acquisition_params": {"base": "EUR", "quote": "KRW"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%not available%' THEN
    RAISE EXCEPTION 'FAIL core-only [Probe]: %', r; END IF;
  r := agent.fn_create_monitor_trigger('{"label": "zz new fx", "trigger_type": "threshold", "acquisition_method": "fx_rate",
         "acquisition_params": {"base": "EUR", "quote": "KRW"}, "comparator": "gte", "threshold_value": 1, "check_interval": "1 day"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL core-only [Anlage]: %', r; END IF;
  -- Abschalten bleibt moeglich ("always silenceable")
  r := agent.fn_set_monitor_trigger('{"label": "zz orphan fx", "status": "disabled"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'FAIL core-only [Disable]: %', r; END IF;
  RAISE NOTICE 'PASS core-only [Monitor: geparkt, Probe/Anlage {ok:false}, Disable geht]';

  PERFORM count(*) FROM core.fn_collect_chat_since();
  RAISE NOTICE 'PASS core-only [Lern-Sammler]';

  r := agent.fn_clear_e2e_data();
  IF r ? 'accounts' THEN RAISE EXCEPTION 'FAIL core-only [E2E]: finance-Hook lief trotz fehlendem Schema: %', r; END IF;
  RAISE NOTICE 'PASS core-only [E2E-Cleanup ohne Paket-Hooks]';

  r := core.fn_reset_onboarding_state();
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'packages' <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL core-only [Onboarding-Reset]: %', r; END IF;
  r := core.fn_reset_user_data('RESET');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'truncated_tables')::int <> 0 OR r->'packages' <> '[]'::jsonb THEN
    RAISE EXCEPTION 'FAIL core-only [Werkszustand-Reset]: %', r; END IF;
  RAISE NOTICE 'PASS core-only [Onboarding-Reset + Werkszustand-Reset]';
END $$;

ROLLBACK;
