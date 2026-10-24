-- tests/db/finance/test_fn_monitor_acquire_fx_rate.sql
-- Phase B: die finance-Monitor-Methode fx_rate (vorher ungeguardet im Core).
--   (validate_fn allein: test_fn_monitor_validate_fx_rate.sql)
--   finance.fn_monitor_acquire_fx_rate: frischer Kurs ok, stale (Override + Config monitor.fx_stale_days) dirty,
--     unbekanntes Paar dirty
--   End-to-end ueber die Core-Registry (agent.fn_monitor_probe + fn_create_monitor_trigger) mit der echten
--     finance-Registrierung (db_test seedet keine Registries -> hier eingefuegt, wie der Installer-Seed).
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;
DELETE FROM finance.fx_rates WHERE base_currency = 'EUR' AND quote_currency = 'KRW';
INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
VALUES ('EUR', 'KRW', 1450.5, '2026-06-09', '__test__');

DO $$
DECLARE r jsonb;
BEGIN
  -- acquire
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "KRW"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1450.5 THEN
    RAISE EXCEPTION 'FAIL acquire fresh: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "KRW"}, "as_of": "2026-06-20", "stale_days": 5}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%stale%' THEN
    RAISE EXCEPTION 'FAIL acquire stale (override): %', r; END IF;
  INSERT INTO core.config (category, key, value, package) VALUES ('monitor', 'fx_stale_days', '30', 'finance')
  ON CONFLICT (category, key) DO UPDATE SET value = '30', package = 'finance';
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "KRW"}, "as_of": "2026-06-20"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL acquire honours finance config monitor.fx_stale_days=30: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "JPY"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL acquire unknown pair: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_acquire_fx_rate [fresh / stale / Config / unbekannt]';

  -- end-to-end ueber die Core-Registry
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
  VALUES ('fx_rate', 'finance.fn_monitor_acquire_fx_rate', 'finance.fn_monitor_validate_fx_rate', 'finance')
  ON CONFLICT (method) DO UPDATE SET acquire_fn = EXCLUDED.acquire_fn, validate_fn = EXCLUDED.validate_fn, package = 'finance';
  r := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'EUR', 'quote', 'KRW'), 'as_of', '2026-06-10'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1450.5
     OR r->'display' IS DISTINCT FROM core.fn_ui_tpl('finance.monitor_display.fx_pair', '{"base":"EUR","quote":"KRW"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL probe via registry: %', r; END IF;
  r := agent.fn_create_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'krw over 1400',
         'trigger_type', 'threshold', 'acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'eur', 'quote', 'krw'),
         'comparator', 'gte', 'threshold_value', 1400, 'check_interval', '1 day'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT acquisition_spec FROM agent.monitor_triggers WHERE id = (r->>'trigger_id')::int) <> '{"base":"EUR","quote":"KRW"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL create via registry (normalisierte Spec): %', r; END IF;
  r := agent.fn_set_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'krw over 1400',
         'acquisition_params', jsonb_build_object('quote', 'XYZ')));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unknown currenc%' THEN
    RAISE EXCEPTION 'FAIL set via registry (merge + validate): %', r; END IF;
  RAISE NOTICE 'PASS fx_rate end-to-end ueber die Core-Registry (probe/create/set)';
END $$;

ROLLBACK;
