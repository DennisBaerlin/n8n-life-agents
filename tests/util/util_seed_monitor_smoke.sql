-- ============================================================
-- util_seed_monitor_smoke.sql — Smoke-Fixtures fuer den Monitor-Cron-Probelauf
-- Legt 4 Sentinel-Trigger (domain '__e2e_monitor__', einer je Beschaffungsart) an,
-- die beim NAECHSTEN Heartbeat-Lauf (Minute 10) alle feuern bzw. Infos liefern:
--   * web:  Goldpreis USD/oz, Schwelle >= 100 (feuert sicher) — testet Grounding+Parse
--   * sql:  recurring_info 'SELECT 42.5' — testet SET LOCAL ROLE finance_ro im Cron
--   * fx:   EUR/KRW >= 1 (feuert sicher) — testet den FX-Fast-Path
--   * date: heute faellig — testet den Termin-Latch
-- Verifikation danach: agent.monitor_observations + Telegram-Message; Aufraeumen:
--   SELECT agent.fn_clear_e2e_data();  (raeumt die Sentinel-Domain inkl. Observations)
-- Idempotent (loescht eigene Sentinel-Zeilen vorher). KEIN Produktiv-Seed.
-- Usage: db_apply.ps1 -File tests\util\util_seed_monitor_smoke.sql
-- ============================================================

DELETE FROM agent.monitor_triggers WHERE domain = '__e2e_monitor__';

INSERT INTO agent.monitor_triggers
    (domain, label, trigger_type, acquisition_method, acquisition_spec,
     comparator, threshold_value, due_date, expected_unit,
     min_plausible, max_plausible, check_interval, action_note)
VALUES
    ('__e2e_monitor__', 'SMOKE web gold', 'threshold', 'web_search',
     jsonb_build_object('prompt', 'Current spot price of gold (XAU) in USD per troy ounce. Plain number, dot decimal.'),
     'gte', 100, NULL, 'USD/oz', 1000, 10000, interval '12 hours',
     'Smoke-Test: Web-Beschaffung ok'),
    ('__e2e_monitor__', 'SMOKE sql fixed', 'recurring_info', 'sql',
     jsonb_build_object('query', 'SELECT 42.5'),
     NULL, NULL, NULL, 'EUR', NULL, NULL, interval '1 day',
     'Smoke-Test: SQL-Beschaffung ok'),
    ('__e2e_monitor__', 'SMOKE fx krw', 'threshold', 'fx_rate',
     jsonb_build_object('base', 'EUR', 'quote', 'KRW'),
     'gte', 1, NULL, NULL, NULL, NULL, interval '1 day',
     'Smoke-Test: FX-Fast-Path ok'),
    ('__e2e_monitor__', 'SMOKE date today', 'date', 'none', '{}'::jsonb,
     NULL, NULL, current_date, NULL, NULL, NULL, interval '1 day',
     'Smoke-Test: Termin-Latch ok');
