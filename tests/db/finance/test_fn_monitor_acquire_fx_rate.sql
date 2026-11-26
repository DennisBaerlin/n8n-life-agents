-- tests/db/finance/test_fn_monitor_acquire_fx_rate.sql
-- Die finance-Monitor-Methode fx_rate.
--   (validate_fn allein: test_fn_monitor_validate_fx_rate.sql)
--   finance.fn_monitor_acquire_fx_rate: frischer Kurs ok, stale (Override + Config monitor.fx_stale_days) dirty,
--     unbekanntes Paar dirty
--   End-to-end ueber die Core-Registry (agent.fn_monitor_probe + fn_create_monitor_trigger) mit der echten
--     finance-Registrierung (db_test seedet keine Registries -> hier eingefuegt, wie der Installer-Seed).
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

INSERT INTO finance.currencies (code, minor_unit) VALUES ('CLP', 0) ON CONFLICT (code) DO NOTHING;
DELETE FROM finance.fx_rates WHERE base_currency = 'EUR' AND quote_currency = 'CLP';
INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
VALUES ('EUR', 'CLP', 1450.5, '2026-06-09', '__test__');

DO $$
DECLARE r jsonb;
BEGIN
  -- acquire
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "CLP"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1450.5 THEN
    RAISE EXCEPTION 'FAIL acquire fresh: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "CLP"}, "as_of": "2026-06-20", "stale_days": 5}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%stale%' THEN
    RAISE EXCEPTION 'FAIL acquire stale (override): %', r; END IF;
  INSERT INTO core.config (category, key, value, package) VALUES ('monitor', 'fx_stale_days', '30', 'finance')
  ON CONFLICT (category, key) DO UPDATE SET value = '30', package = 'finance';
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "CLP"}, "as_of": "2026-06-20"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'FAIL acquire honours finance config monitor.fx_stale_days=30: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "JPY"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL acquire unknown pair: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_acquire_fx_rate [fresh / stale / Config / unbekannt]';

  -- Paare ohne EUR-Basis ueber finance.fn_fx_rate (invers / gekreuzt)
  PERFORM finance.fn_ensure_currency('USD');
  DELETE FROM finance.fx_rates WHERE quote_currency = 'USD';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source)
  VALUES ('EUR', 'USD', 1.25, '2026-06-05', '__test__');
  -- [15] CLP/EUR und USD/CLP liefern ok:true
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "CLP", "quote": "EUR"}, "as_of": "2026-06-10", "stale_days": 30}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1 / 1450.5 THEN
    RAISE EXCEPTION 'FAIL [15] inverse pair CLP/EUR: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "USD", "quote": "CLP"}, "as_of": "2026-06-10", "stale_days": 30}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1450.5 / 1.25
     OR r->>'unit' IS DISTINCT FROM 'CLP per USD' THEN
    RAISE EXCEPTION 'FAIL [15] cross pair USD/CLP: %', r; END IF;
  -- [16] Alters-Pruefung am aelteren der beiden Kurs-Daten (USD 2026-06-05, CLP 2026-06-09)
  IF r->>'as_of' IS DISTINCT FROM '2026-06-05' THEN
    RAISE EXCEPTION 'FAIL [16] as_of must be the older date: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "USD", "quote": "CLP"}, "as_of": "2026-06-10", "stale_days": 3}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%stale%' THEN
    RAISE EXCEPTION 'FAIL [16] stale on the older side: %', r; END IF;
  -- [16b] Stichtag vor dem ersten Kurs: ein spaeterer Kurs ist keine Beobachtung fuer diesen Tag -> "no fx rate"
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "EUR", "quote": "USD"}, "as_of": "2026-01-01", "stale_days": 30}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE 'no fx rate%' THEN
    RAISE EXCEPTION 'FAIL [16b] rate after as_of must not count: %', r; END IF;
  -- [16c] Kreuzpaar, nur eine Seite faellt auf einen spaeteren Kurs zurueck (JPY erst ab 2026-07-01) -> "no fx rate"
  PERFORM finance.fn_ensure_currency('JPY');
  DELETE FROM finance.fx_rates WHERE quote_currency = 'JPY';
  INSERT INTO finance.fx_rates (base_currency, quote_currency, rate, as_of, source) VALUES ('EUR', 'JPY', 1500, '2026-07-01', '__test__');
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "USD", "quote": "JPY"}, "as_of": "2026-06-10", "stale_days": 30}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE 'no fx rate%' THEN
    RAISE EXCEPTION 'FAIL [16c] one side only after as_of: %', r; END IF;
  -- [17] Waehrung ohne jede Zeile -> "no fx rate" bleibt
  PERFORM finance.fn_ensure_currency('XTS');
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "USD", "quote": "XTS"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE 'no fx rate%' THEN
    RAISE EXCEPTION 'FAIL [17] no rate at all: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_acquire_fx_rate [15 ohne EUR-Basis, 16 aelteres Datum, 17 kein Kurs]';

  -- [m] Edelmetall: Preis je Einheit = fn_fx_rate(Metall, quote) x fn_metal_unit_factor(unit), Kreuzkurs ueber EUR
  DELETE FROM finance.fx_rates WHERE quote_currency = 'XAU';
  PERFORM finance.fn_upsert_fx_rates('{"rows":[{"date":"2026-06-08","base":"XAU","quote":"EUR","rate":3200}]}'::jsonb);
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "EUR", "unit": "ozt"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 3200) > 0.001
     OR r->>'unit' IS DISTINCT FROM 'EUR per XAU ozt' OR r->>'as_of' IS DISTINCT FROM '2026-06-08' THEN
    RAISE EXCEPTION 'FAIL [m ozt]: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "EUR", "unit": "g"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 3200 / 31.1034768) > 0.0001
     OR r->>'unit' IS DISTINCT FROM 'EUR per XAU g' THEN
    RAISE EXCEPTION 'FAIL [m g]: %', r; END IF;
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "EUR", "unit": "kg"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 3200 * 1000 / 31.1034768) > 0.1 THEN
    RAISE EXCEPTION 'FAIL [m kg]: %', r; END IF;
  -- ohne unit (gespeicherte Spec vor der Einheit gibt es nicht, aber die Probe darf sie weglassen) -> Feinunze
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "EUR"}, "as_of": "2026-06-10"}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 3200) > 0.001 THEN
    RAISE EXCEPTION 'FAIL [m ohne unit]: %', r; END IF;
  -- Kreuzkurs: USD 1,25 je EUR -> 4000 USD je Unze
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "USD", "unit": "ozt"}, "as_of": "2026-06-10", "stale_days": 30}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 4000) > 0.01 THEN
    RAISE EXCEPTION 'FAIL [m Kreuzkurs XAU/USD]: %', r; END IF;
  -- Metall-Zeile aelter als fx_stale_days -> stale (der Waechter meldet den Ausfall der Quelle selbst)
  r := finance.fn_monitor_acquire_fx_rate('{"spec": {"base": "XAU", "quote": "EUR", "unit": "ozt"}, "as_of": "2026-06-20", "stale_days": 5}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%stale%' THEN
    RAISE EXCEPTION 'FAIL [m stale]: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_acquire_fx_rate [m Metall ozt/g/kg, ohne unit, Kreuzkurs, stale]';

  -- end-to-end ueber die Core-Registry
  INSERT INTO core.package_registry (package, status) VALUES ('finance', 'active')
  ON CONFLICT (package) DO UPDATE SET status = 'active';
  INSERT INTO core.monitor_acquisition_methods (method, acquire_fn, validate_fn, package)
  VALUES ('fx_rate', 'finance.fn_monitor_acquire_fx_rate', 'finance.fn_monitor_validate_fx_rate', 'finance')
  ON CONFLICT (method) DO UPDATE SET acquire_fn = EXCLUDED.acquire_fn, validate_fn = EXCLUDED.validate_fn, package = 'finance';
  r := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'EUR', 'quote', 'CLP'), 'as_of', '2026-06-10'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR (r->>'value')::numeric IS DISTINCT FROM 1450.5
     OR r->'display' IS DISTINCT FROM core.fn_ui_tpl('finance.monitor_display.fx_pair', '{"base":"EUR","quote":"CLP"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL probe via registry: %', r; END IF;
  r := agent.fn_create_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'clp over 1400',
         'trigger_type', 'threshold', 'acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'eur', 'quote', 'clp'),
         'comparator', 'gte', 'threshold_value', 1400, 'check_interval', '1 day'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT acquisition_spec FROM agent.monitor_triggers WHERE id = (r->>'trigger_id')::int) <> '{"base":"EUR","quote":"CLP"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL create via registry (normalisierte Spec): %', r; END IF;
  r := agent.fn_set_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'clp over 1400',
         'acquisition_params', jsonb_build_object('quote', 'XYZ')));
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unknown currenc%' THEN
    RAISE EXCEPTION 'FAIL set via registry (merge + validate): %', r; END IF;
  RAISE NOTICE 'PASS fx_rate end-to-end ueber die Core-Registry (probe/create/set)';

  -- Gold-Waechter in Euro: Schwelle bleibt in der Waehrung des Nutzers, Karte (Probe) und erster Messwert aus derselben fn
  r := agent.fn_monitor_probe(jsonb_build_object('acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'XAU', 'quote', 'EUR'), 'as_of', '2026-06-10'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR abs((r->>'value')::numeric - 3200) > 0.001
     OR r->'display' IS DISTINCT FROM finance.fn_monitor_validate_fx_rate('{"params": {"base": "XAU", "quote": "EUR"}}')->'display' THEN
    RAISE EXCEPTION 'FAIL probe gold via registry: %', r; END IF;
  UPDATE finance.fx_rates SET as_of = CURRENT_DATE WHERE quote_currency = 'XAU';
  r := agent.fn_create_monitor_trigger(jsonb_build_object('domain', '__test__', 'label', 'gold below 3100',
         'trigger_type', 'threshold', 'acquisition_method', 'fx_rate',
         'acquisition_params', jsonb_build_object('base', 'xau', 'quote', 'eur'),
         'comparator', 'lte', 'threshold_value', 3100, 'check_interval', '1 day'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true
     OR (SELECT acquisition_spec FROM agent.monitor_triggers WHERE id = (r->>'trigger_id')::int)
        <> '{"base":"XAU","quote":"EUR","unit":"ozt"}'::jsonb
     OR (SELECT threshold_value FROM agent.monitor_triggers WHERE id = (r->>'trigger_id')::int) IS DISTINCT FROM 3100::numeric THEN
    RAISE EXCEPTION 'FAIL create gold trigger via registry: %', r; END IF;
  RAISE NOTICE 'PASS fx_rate Gold-Waechter end-to-end (probe/create, Schwelle unveraendert in EUR)';
END $$;

ROLLBACK;
