-- tests/db/finance/test_fn_monitor_validate_fx_rate.sql
-- validate_fn der finance-Monitor-Methode fx_rate.
--   finance.fn_monitor_validate_fx_rate: Paar normalisiert (Grossbuchstaben, getrimmt) + display;
--   unbekannte Waehrung / fehlender Code -> {ok:false}; Idempotenz-Vertrag (eigene spec als params -> gleiche spec)
--   (Beschaffung + End-to-end ueber die Core-Registry: test_fn_monitor_acquire_fx_rate.sql)
-- BEGIN...ROLLBACK -> kein Residual-State.
BEGIN;

INSERT INTO finance.currencies (code, minor_unit) VALUES ('CLP', 0) ON CONFLICT (code) DO NOTHING;

DO $$
DECLARE r jsonb;
BEGIN
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "eur", "quote": " clp "}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"EUR","quote":"CLP"}'::jsonb
     OR r->'display' IS DISTINCT FROM core.fn_ui_tpl('finance.monitor_display.fx_pair', '{"base":"EUR","quote":"CLP"}'::jsonb) THEN
    RAISE EXCEPTION 'FAIL validate happy: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR", "quote": "XYZ"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unknown currenc%' THEN
    RAISE EXCEPTION 'FAIL validate unknown ccy: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false THEN RAISE EXCEPTION 'FAIL validate missing quote: %', r; END IF;
  -- Idempotenz-Vertrag (§3.9): die normalisierte spec erneut als params -> ok, dieselbe spec
  r := finance.fn_monitor_validate_fx_rate(jsonb_build_object('params',
         finance.fn_monitor_validate_fx_rate('{"params": {"base": "eur", "quote": " clp "}}')->'spec'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"EUR","quote":"CLP"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL validate idempotent: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_validate_fx_rate [normalisiert / unbekannt / fehlend / idempotent]';

  -- Edelmetalle: nur als base, Einheit ozt|g|kg (Default ozt, nur bei Metall), display = Metall-Preis-Vorlage
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "xau", "quote": "eur"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"XAU","quote":"EUR","unit":"ozt"}'::jsonb
     OR r->'display' IS DISTINCT FROM core.fn_ui_tpl('finance.monitor_display.metal_price', jsonb_build_object(
          'metal', core.fn_ui_tpl('finance.value.metal_xau'), 'quote', 'EUR', 'unit', core.fn_ui_tpl('finance.value.metal_unit_ozt'))) THEN
    RAISE EXCEPTION 'FAIL validate metal default ozt: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "XAG", "quote": "CLP", "unit": " G "}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"XAG","quote":"CLP","unit":"g"}'::jsonb
     OR r->'display'->'params'->'unit' IS DISTINCT FROM core.fn_ui_tpl('finance.value.metal_unit_g')
     OR r->'display'->'params'->'metal' IS DISTINCT FROM core.fn_ui_tpl('finance.value.metal_xag') THEN
    RAISE EXCEPTION 'FAIL validate metal unit g: %', r; END IF;
  -- Idempotenz mit unit
  r := finance.fn_monitor_validate_fx_rate(jsonb_build_object('params', r->'spec'));
  IF (r->>'ok')::boolean IS DISTINCT FROM true OR r->'spec' <> '{"base":"XAG","quote":"CLP","unit":"g"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL validate metal idempotent: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR", "quote": "CLP", "unit": "g"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unit%' THEN
    RAISE EXCEPTION 'FAIL validate unit on currency pair: %', r; END IF;
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "XAU", "quote": "EUR", "unit": "lb"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%unit%' THEN
    RAISE EXCEPTION 'FAIL validate unknown unit: %', r; END IF;
  -- Richtung: Metall als quote -> abgelehnt mit Hinweis (das Modell dreht nicht selbst um)
  r := finance.fn_monitor_validate_fx_rate('{"params": {"base": "EUR", "quote": "XAU"}}');
  IF (r->>'ok')::boolean IS DISTINCT FROM false OR r->>'reason' NOT ILIKE '%"base":"XAU"%' THEN
    RAISE EXCEPTION 'FAIL validate metal as quote: %', r; END IF;
  RAISE NOTICE 'PASS fn_monitor_validate_fx_rate [Metall: Default ozt, g, idempotent, unit nur bei Metall, unbekannte Einheit, Richtung]';
END $$;

ROLLBACK;
