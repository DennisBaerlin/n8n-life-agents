-- tests/db/finance/test_fn_app_low_state_banner.sql
-- finance.fn_app_low_state_banner(p_ls jsonb, p_account text, p_sugg jsonb) — der EINE Startseiten-Hinweis zum Urteil
-- „Tiefster Stand" (Konten-probe fuer gelistete Konten, Ziele-probe fuer Kinder-Konten in der Haushalts-Sicht).
--   1) verdict goals alert -> „{account}: Das Geld ... reicht nur bis {date}" (on_date).
--   2) verdict buffer alert -> „... unter dem Puffer" mit tiefstem Stand + Tag des Tiefs; mit Vorschlag -> _suggest.
--   3) verdict buffer warn -> „Es wird knapp"; goals warn / ok / neutral / ohne state / {ok:false} / NULL -> NULL.
--   Das Ziel (target) setzt der Aufrufer.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  b jsonb := '{"ok":true,"currency":"EUR","source":"outlook","verdict":"buffer","amount":140,"low_date":"2026-11-27","on_date":"2026-11-27","buffer":250,"short_by":110,"gap":false}';
  g jsonb := '{"ok":true,"currency":"EUR","source":"funding","verdict":"goals","amount":-50,"low_date":"2027-05-01","on_date":"2027-04-01","gap":false}';
  s jsonb := '{"amount":150,"from_account":"Tagesgeld","by_date":"2026-11-25"}';
BEGIN
  IF finance.fn_app_low_state_banner(g || '{"state":"alert"}', 'Taschengeld', NULL) <> jsonb_build_object(
       'state', 'alert', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.accounts.banner_gap',
         jsonb_build_object('account', 'Taschengeld', 'date', core.fn_ui_date('2027-04-01')))) THEN
    RAISE EXCEPTION 'FAIL [1] goals alert, got %', finance.fn_app_low_state_banner(g || '{"state":"alert"}', 'Taschengeld', NULL); END IF;
  RAISE NOTICE 'PASS [1] goals alert';

  IF finance.fn_app_low_state_banner(b || '{"state":"alert"}', 'Giro', NULL) <> jsonb_build_object(
       'state', 'alert', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.accounts.banner_short',
         jsonb_build_object('account', 'Giro', 'min', core.fn_ui_money(140, 'EUR'), 'date', core.fn_ui_date('2026-11-27')))) THEN
    RAISE EXCEPTION 'FAIL [2a] buffer alert'; END IF;
  IF finance.fn_app_low_state_banner(b || '{"state":"alert"}', 'Giro', s) <> jsonb_build_object(
       'state', 'alert', 'icon', 'alert', 'text', core.fn_ui_tpl('finance.app.accounts.banner_short_suggest',
         jsonb_build_object('account', 'Giro', 'min', core.fn_ui_money(140, 'EUR'), 'date', core.fn_ui_date('2026-11-27'),
           'amount', core.fn_ui_money(150, 'EUR'), 'from', 'Tagesgeld', 'by', core.fn_ui_date('2026-11-25')))) THEN
    RAISE EXCEPTION 'FAIL [2b] buffer alert mit Vorschlag'; END IF;
  RAISE NOTICE 'PASS [2] buffer alert (+ Vorschlag)';

  IF finance.fn_app_low_state_banner(b || '{"state":"warn"}', 'Giro', NULL) <> jsonb_build_object(
       'state', 'warn', 'icon', 'clock', 'text', core.fn_ui_tpl('finance.app.accounts.banner_tight',
         jsonb_build_object('account', 'Giro', 'min', core.fn_ui_money(140, 'EUR'), 'date', core.fn_ui_date('2026-11-27')))) THEN
    RAISE EXCEPTION 'FAIL [3a] buffer warn'; END IF;
  IF finance.fn_app_low_state_banner(g || '{"state":"warn"}', 'x', NULL) IS NOT NULL
     OR finance.fn_app_low_state_banner(b || '{"state":"ok"}', 'x', NULL) IS NOT NULL
     OR finance.fn_app_low_state_banner(b || '{"state":"neutral"}', 'x', NULL) IS NOT NULL
     OR finance.fn_app_low_state_banner(b, 'x', NULL) IS NOT NULL
     OR finance.fn_app_low_state_banner('{"ok":false}', 'x', NULL) IS NOT NULL
     OR finance.fn_app_low_state_banner(NULL, 'x', NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3b] goals warn / ok / neutral / ohne state / ok:false / NULL -> kein Banner'; END IF;
  RAISE NOTICE 'PASS [3] knapp + keine Banner ohne Handlungsbedarf';
END $$;
ROLLBACK;
