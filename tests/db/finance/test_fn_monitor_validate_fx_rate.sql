-- tests/db/finance/test_fn_monitor_validate_fx_rate.sql
-- Phase B: validate_fn der finance-Monitor-Methode fx_rate.
--   finance.fn_monitor_validate_fx_rate: Paar normalisiert (Grossbuchstaben, getrimmt) + display;
--   unbekannte Waehrung / fehlender Code -> {ok:false}; Idempotenz-Vertrag (eigene spec als params -> gleiche spec)
--   (Beschaffung + End-to-end ueber die Core-Registry: test_fn_monitor_acquire_fx_rate.sql)
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

INSERT INTO finance.currencies (code, minor_unit) VALUES ('KRW', 0) ON CONFLICT (code) DO NOTHING;

DO $$
DECLARE r jsonb;
BEGIN
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "eur", "quote": " krw "}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"EUR","quote":"KRW"}'::jsonb
     OR r->'display' IS DISTINCT FROM core.fn_ui_tpl('finance.monitor_display.fx_pair', '{"base":"EUR","quote":"KRW"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL validate happy: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR", "quote": "XYZ"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unknown currenc%' THEN
    RAISE EXCEPTION 'FAIL validate unknown ccy: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL validate missing quote: %', r; END IF;
  -- Idempotenz-Vertrag (§3.9): die normalisierte spec erneut als params -> ok, dieselbe spec
  r := finance.fn_monitor_validate_fx_rate(jsonb_build_object('params',
         finance.fn_monitor_validate_fx_rate('{"params": {"base": "eur", "quote": " krw "}}')->'spec'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"EUR","quote":"KRW"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL validate idempotent: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_validate_fx_rate [normalisiert / unbekannt / fehlend / idempotent]';
END $$;

ROLLBACK;
