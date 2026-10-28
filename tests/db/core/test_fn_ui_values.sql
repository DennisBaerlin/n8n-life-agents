-- tests/db/core/test_fn_ui_values.sql
-- Struktur-Bausteine fester Texte (Textkatalog Phase C): core.fn_ui_tpl / fn_ui_money / fn_ui_num / fn_ui_date
--   liefern die HITL-Form, die der Workflow-Renderer (Get-UiRenderLibJs) in der Empfaenger-Sprache rendert.
BEGIN;

DO $$
DECLARE
  v jsonb;
BEGIN
  v := core.fn_ui_tpl('finance.advisor.x', jsonb_build_object('n', core.fn_ui_num(3.456, 1, true),
         'm', core.fn_ui_money(1234.567, 'USD'), 'd', core.fn_ui_date('2026-03-05'), 's', 'Text'));
  IF v->>'kind' <> 'tpl' OR v->>'value' <> 'finance.advisor.x' THEN RAISE EXCEPTION 'FAIL ui_tpl [Form: %]', v; END IF;
  IF v->'params'->'n' <> '{"kind":"number","value":3.5,"digits":1,"sign":true}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_num [%]', v->'params'->'n'; END IF;
  IF v->'params'->'m' <> '{"kind":"money","value":1234.57,"currency":"USD"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_money [%]', v->'params'->'m'; END IF;
  IF v->'params'->'d' <> '{"kind":"date","value":"2026-03-05"}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_date [%]', v->'params'->'d'; END IF;
  IF v->'params'->>'s' <> 'Text' THEN RAISE EXCEPTION 'FAIL ui_tpl [einfacher Parameter]'; END IF;
  -- Defaults + NULL-Robustheit
  IF core.fn_ui_tpl('core.a.b')->'params' <> '{}'::jsonb OR core.fn_ui_tpl('core.a.b', NULL)->'params' <> '{}'::jsonb THEN
    RAISE EXCEPTION 'FAIL ui_tpl [leere params]'; END IF;
  IF core.fn_ui_money(NULL)->'value' <> 'null'::jsonb OR core.fn_ui_money(5)->>'currency' <> 'EUR' THEN
    RAISE EXCEPTION 'FAIL ui_money [NULL/Default: %]', core.fn_ui_money(NULL); END IF;
  -- Vorzeichen (Uebersicht R3): nur bei p_sign der Schluessel sign, sonst Form unveraendert
  IF core.fn_ui_money(12.345, 'EUR', true) <> '{"kind":"money","value":12.35,"currency":"EUR","sign":true}'::jsonb
     OR core.fn_ui_money(-3, 'EUR', false) ? 'sign' OR core.fn_ui_money(1, 'USD') ? 'sign' THEN
    RAISE EXCEPTION 'FAIL ui_money [sign: %]', core.fn_ui_money(12.345, 'EUR', true); END IF;
  IF (SELECT count(*) FROM pg_proc WHERE proname = 'fn_ui_money' AND pronamespace = 'core'::regnamespace) <> 1 THEN
    RAISE EXCEPTION 'FAIL ui_money [genau eine Signatur, sonst mehrdeutig]'; END IF;
  IF core.fn_ui_num(7)->>'digits' <> '0' OR (core.fn_ui_num(7)->>'sign')::boolean THEN
    RAISE EXCEPTION 'FAIL ui_num [Default]'; END IF;
  IF core.fn_ui_date(NULL)->'value' <> 'null'::jsonb THEN RAISE EXCEPTION 'FAIL ui_date [NULL]'; END IF;
  RAISE NOTICE 'PASS fn_ui_tpl/money/num/date [Form, Rundung, Defaults, NULL]';
END $$;

ROLLBACK;
