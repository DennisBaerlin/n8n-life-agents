-- tests/db/finance/test_fn_app_low_state_pill.sql
-- finance.fn_app_low_state_pill(p_ls jsonb) — die EINE Pille zum Urteil „Tiefster Stand" (fn_account_low_state), die
-- Konten-Zeile (fn_app_screen_accounts) und Spiegel-Pille am Sparplan (fn_app_screen_goals) gleich zeigen.
--   1) verdict buffer: warn „knapp ueber dem Puffer ({buffer})", alert „{amount} unter dem Puffer" mit short_by.
--   2) verdict goals: warn „reicht bis {month}", alert „Luecke ab {date}".
--   3) ok / neutral (Kurs fehlt) / ohne state / {ok:false} / NULL -> keine Pille.
-- Self-contained (BEGIN..ROLLBACK).
BEGIN;
DO $$
DECLARE
  b jsonb := '{"ok":true,"currency":"EUR","source":"outlook","verdict":"buffer","amount":140,"buffer":250,"short_by":110,"gap":false,"on_date":"2026-11-27"}';
  g jsonb := '{"ok":true,"currency":"EUR","source":"funding","verdict":"goals","amount":-50,"buffer":null,"short_by":null,"gap":false,"on_date":"2027-04-01"}';
BEGIN
  IF finance.fn_app_low_state_pill(b || '{"state":"warn"}') <> jsonb_build_object('state', 'warn', 'icon', 'clock',
       'text', core.fn_ui_tpl('finance.app.accounts.pill_tight', jsonb_build_object('buffer', core.fn_ui_money(250, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1a] buffer warn, got %', finance.fn_app_low_state_pill(b || '{"state":"warn"}'); END IF;
  IF finance.fn_app_low_state_pill(b || '{"state":"alert"}') <> jsonb_build_object('state', 'alert', 'icon', 'alert',
       'text', core.fn_ui_tpl('finance.app.accounts.pill_short', jsonb_build_object('amount', core.fn_ui_money(110, 'EUR')))) THEN
    RAISE EXCEPTION 'FAIL [1b] buffer alert mit short_by, got %', finance.fn_app_low_state_pill(b || '{"state":"alert"}'); END IF;
  RAISE NOTICE 'PASS [1] verdict buffer';

  IF finance.fn_app_low_state_pill(g || '{"state":"warn"}') <> jsonb_build_object('state', 'warn', 'icon', 'calendar',
       'text', core.fn_ui_tpl('finance.app.accounts.pill_until', jsonb_build_object('month', core.fn_ui_month('2027-04-01')))) THEN
    RAISE EXCEPTION 'FAIL [2a] goals warn, got %', finance.fn_app_low_state_pill(g || '{"state":"warn"}'); END IF;
  IF finance.fn_app_low_state_pill(g || '{"state":"alert"}') <> jsonb_build_object('state', 'alert', 'icon', 'alert',
       'text', core.fn_ui_tpl('finance.app.accounts.pill_gap', jsonb_build_object('date', core.fn_ui_date('2027-04-01')))) THEN
    RAISE EXCEPTION 'FAIL [2b] goals alert, got %', finance.fn_app_low_state_pill(g || '{"state":"alert"}'); END IF;
  RAISE NOTICE 'PASS [2] verdict goals';

  IF finance.fn_app_low_state_pill(b || '{"state":"ok"}') IS NOT NULL
     OR finance.fn_app_low_state_pill(b || '{"state":"neutral"}') IS NOT NULL
     OR finance.fn_app_low_state_pill(b) IS NOT NULL
     OR finance.fn_app_low_state_pill('{"ok":true,"verdict":"goals"}') IS NOT NULL
     OR finance.fn_app_low_state_pill('{"ok":false}') IS NOT NULL
     OR finance.fn_app_low_state_pill(NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'FAIL [3] ok/neutral/ohne state/ok:false/NULL -> keine Pille'; END IF;
  RAISE NOTICE 'PASS [3] ohne Handlungsbedarf keine Pille';
END $$;
ROLLBACK;
